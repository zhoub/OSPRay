// ======================================================================== //
// Copyright 2009-2016 Intel Corporation                                    //
//                                                                          //
// Licensed under the Apache License, Version 2.0 (the "License");          //
// you may not use this file except in compliance with the License.         //
// You may obtain a copy of the License at                                  //
//                                                                          //
//     http://www.apache.org/licenses/LICENSE-2.0                           //
//                                                                          //
// Unless required by applicable law or agreed to in writing, software      //
// distributed under the License is distributed on an "AS IS" BASIS,        //
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. //
// See the License for the specific language governing permissions and      //
// limitations under the License.                                           //
// ======================================================================== //

#include "PathTracer.ih"
#include "camera/Camera.ih"

#include "render/pathtracer/materials/Medium.ih"
#include "render/pathtracer/materials/Material.ih"
#include "math/random.ih"
#include "fb/LocalFB.ih"

#define PDF_CULLING 0.0f
//#define USE_DGCOLOR


inline float misHeuristic(float pdf1, float pdf2)
{
  // power heuristic with beta=2
  const float p = sqr(pdf1) * rcp(sqr(pdf1) + sqr(pdf2));
  // guard against high pdf (including Dirac delta)
  // using the limit when pdf1 approaches inf
  // compare with bit less than sqrt(float_max) (when sqr starts to overflow)
  return pdf1 > 1e17f ? 1.0f : p;
}

// TODO use intersection filters
vec3f transparentShadow(const uniform PathTracer* uniform self,
                        vec3f lightContrib,
                        Ray &shadowRay,
                        Medium medium)
{
  int max_depth = self->maxDepth;
  const float org_t_max = shadowRay.t;

  while (1) {
    traceRay(self->super.model, shadowRay);

    if (noHit(shadowRay))
      return lightContrib;

    DifferentialGeometry dg;
    postIntersect(self->super.model, dg, shadowRay,
        DG_MATERIALID|
        DG_NS|DG_NG|DG_FACEFORWARD|DG_NORMALIZE|DG_TEXCOORD|DG_COLOR
        );

    uniform PathTraceMaterial *m = (uniform PathTraceMaterial*)dg.material;
    vec3f transparency;
    foreach_unique(mm in m)
      if (mm != NULL)
        transparency = mm->getTransparency(mm, dg, shadowRay, medium);

    lightContrib = lightContrib * transparency;

    /*! Compute simple volumetric effect. */
    if (ne(medium.transmission, make_vec3f(1.f)))
      lightContrib = lightContrib * powf(medium.transmission,
                                         shadowRay.t - shadowRay.t0);

    if (reduce_max(lightContrib) <= self->minContribution)
      return lightContrib;

    if (--max_depth <= 0)
      return make_vec3f(0.f);

    /*! Tracking medium if we hit a medium interface. */
    foreach_unique(mm in m)
      if (mm != NULL)
        mm->selectNextMedium(mm, medium);

    shadowRay.t0 = shadowRay.t + self->super.epsilon;
    shadowRay.t = org_t_max;
    shadowRay.primID = -1;
    shadowRay.geomID = -1;
    shadowRay.instID = -1;
  }
}

ScreenSample PathTraceIntegrator_Li(const uniform PathTracer* uniform self,
                             const vec2f &pixel, // normalized, i.e. in [0..1]
                             Ray &ray,
                             varying RandomTEA* uniform rng)
{
  ScreenSample sample;
  sample.alpha = 1.f;

  vec3f L = make_vec3f(0.f); // accumulated radiance
  vec3f Lw = make_vec3f(1.f); // path throughput
  Medium currentMedium = make_Medium_vacuum();
  float lastBSDFPdf = inf; // probability density of previous sampled BSDF, for MIS
  bool straightPath = true; // path from camera did not change direction, for alpha and backplate
  uniform uint32 depth = 0;
  // geometric configuration of last surface interaction
  DifferentialGeometry lastDg;
  // P and N also used by light eval
  lastDg.P = ray.org;
  lastDg.Ns = ray.dir;
  lastDg.Ng = ray.dir;

  DifferentialGeometry previousDg;

  bool insideSolid = false;// Quick fix for glass absorption.

  do {
    traceRay(self->super.model, ray);

    // record depth of primary rays
    if (depth == 0)
      sample.z = ray.t;

    const vec3f wo = neg(ray.dir);

    float maxLightDist = ray.t; // per default, virtual lights are occluded by hit geometry

    // environment shading when nothing hit
    if (noHit(ray)) {
      maxLightDist = inf; // also include envLights (i.e. the ones in infinity)
      if (straightPath) {
        sample.alpha = 1.0f - luminance(Lw);
      }
      if ((bool)self->backplate & straightPath) {
        L = L + Lw * get3f(self->backplate, clamp2edge(self->backplate, pixel));
        maxLightDist = 1e38; // backplate hides envLights (i.e. the ones at infinity)
      }
    }

    // add light from virtual lights by intersecting them
    for (uniform int i = 0; i < self->numLights; i++) {
      const uniform Light *uniform l = self->lights[i];
      Light_EvalRes le = l->eval(l, lastDg, ray.dir);
      if (le.dist <= maxLightDist)
        L = L + Lw * le.radiance * misHeuristic(lastBSDFPdf, le.pdf);
    }

    if (noHit(ray))
      break;

    // terminate after evaluation of lights and before next shading to always have both samples for MIS
    if (depth >= self->maxDepth)
      break;

    ////////////////////////////////////
    // handle next surface interaction

    DifferentialGeometry dg;
    postIntersect(self->super.model, dg, ray,
        DG_MATERIALID|
        DG_NS|DG_NG|DG_FACEFORWARD|DG_NORMALIZE|DG_TEXCOORD|DG_COLOR|DG_TANGENTS
        );

    // shade surface
    uniform ShadingContext ctx;
    ShadingContext_Constructor(&ctx);
    const varying BSDF* bsdf = NULL;

    uniform PathTraceMaterial* m = (uniform PathTraceMaterial*)dg.material;
    foreach_unique(mm in m)
      if (mm != NULL)
        bsdf = mm->getBSDF(mm, &ctx, dg, ray, currentMedium);

    // direct lighting including shadows and MIS
    if (bsdf && (bsdf->type & BSDF_SMOOTH))
    {
      uniform int numLights = self->lights ? min(MAX_LIGHTS, self->numLights) : 0;
      for (uniform int i = 0; i < numLights; i++)
      {
        const uniform Light *uniform light = self->lights[i];

        Light_SampleRes ls = light->sample(light, dg, RandomTEA__getFloats(rng));

        // skip when zero contribution from light
        if (reduce_max(ls.weight) <= 0.0f | ls.pdf <= PDF_CULLING)
          continue;

        // evaluate BSDF
        BSDF_EvalRes fe;
        foreach_unique(f in bsdf)
          if (f != NULL)
            fe = f->eval(f, wo, ls.dir);

#ifdef USE_DGCOLOR
        fe.value = fe.value * make_vec3f(dg.color);
#endif
        // skip when zero contribution from material
        if (reduce_max(fe.value) <= 0.0f)
          continue;

        // test for shadows
        Ray shadow_ray;
        setRay(shadow_ray, dg.P, ls.dir,
               self->super.epsilon, ls.dist - self->super.epsilon);
        shadow_ray.time = ray.time;

        const vec3f unshaded_light_contrib = Lw * ls.weight * fe.value * misHeuristic(ls.pdf, fe.pdf);
        L = L + transparentShadow(self, unshaded_light_contrib, shadow_ray, currentMedium);
      }
    }

    // sample BSDF
    vec2f s  = RandomTEA__getFloats(rng);
    vec2f ss = RandomTEA__getFloats(rng); // FIXME: should be only one component
    BSDF_SampleRes fs;
    foreach_unique(f in bsdf)
      if (f != NULL)
        fs = f->sample(f, wo, s, ss.x);

#ifdef USE_DGCOLOR
    if ((type & GLOSSY_REFLECTION) == NONE) // only colorize diffuse component
      fs.weight = fs.weight * make_vec3f(dg.color);
#endif

    // terminate path when zero contribution from material
    if (reduce_max(fs.weight) <= 0.0f | fs.pdf <= PDF_CULLING)
      break;

    Lw = Lw * fs.weight;

    // compute simple volumetric effect
    const vec3f transmission = currentMedium.transmission;
    if (ne(transmission,make_vec3f(1.f))) {
      Lw = Lw * powf(transmission, ray.t);
    }

    if (insideSolid) {// For absorbing translucent materials.
      foreach_unique(uniMat in dg.material) {
        uniform PathTraceMaterial* uniform m = (uniform PathTraceMaterial *)uniMat;
        if (m != NULL) {
          Lw = Lw * m->getAbsorption(m, previousDg, ray.t);
        }
      }
    }

    // update currentMedium if we hit a medium interface 
    // TODO: support nested dielectrics
    if (fs.type & BSDF_TRANSMISSION) {

      // This is a quick fix for glass. This only works if all solid objects are disjoint 
      // (some space is between them and they don't overlap).
      insideSolid = !insideSolid;

      foreach_unique(uniMat in dg.material) {
        uniform PathTraceMaterial* uniform m = (uniform PathTraceMaterial *)uniMat;
        if (m != NULL) {
          m->selectNextMedium(m, currentMedium);
        }
      }
    }

    // keep lastBSDFPdf and lastDg when there was a Dirac transmission
    // to better combine MIS with transparent shadows
    if (fs.type & ~BSDF_SPECULAR_TRANSMISSION) {
      lastBSDFPdf = fs.pdf;
      lastDg = dg;
    }

    previousDg = dg;

    // continue the path
    straightPath &= eq(ray.dir, fs.wi);
    setRay(ray, dg.P, fs.wi, self->super.epsilon, inf);
    depth++;
  } while (reduce_max(Lw) > self->minContribution);

  sample.rgb = L;
  if (isnan(L.x) || isnan(L.y) || isnan(L.z)){
    sample.rgb = make_vec3f(0.0f,0.0f,0.0f);
    sample.alpha = 1.0f;
  }
  return sample;
}


inline ScreenSample PathTracer_renderPixel(uniform PathTracer *uniform self,
                                           const uint32 ix,
                                           const uint32 iy,
                                           const uint32 accumID)
{
  uniform FrameBuffer *uniform fb = self->super.fb;

  uniform Camera *uniform camera = self->super.camera;
  ScreenSample screenSample;
  screenSample.rgb = make_vec3f(0.f);
  screenSample.alpha = 0.f;
  screenSample.z = inf;

  screenSample.sampleID.x = ix;
  screenSample.sampleID.y = iy;

  // init RNG
  RandomTEA rng_state; varying RandomTEA* const uniform rng = &rng_state;
  RandomTEA__Constructor(rng, fb->size.x*iy+ix, accumID);
  const int spp = max(1, self->super.spp);

  for (uniform int s=0; s < spp; s++) {
    screenSample.sampleID.z = accumID*spp + s;

    CameraSample cameraSample;
    const vec2f pixelSample = RandomTEA__getFloats(rng);
    cameraSample.screen.x = (screenSample.sampleID.x + pixelSample.x) * fb->rcpSize.x;
    cameraSample.screen.y = (screenSample.sampleID.y + pixelSample.y) * fb->rcpSize.y;
    cameraSample.lens     = RandomTEA__getFloats(rng);

    camera->initRay(camera, screenSample.ray, cameraSample);
    const vec2f timeSample = RandomTEA__getFloats(rng);
    screenSample.ray.time = timeSample.x;

    ScreenSample sample = PathTraceIntegrator_Li(self, cameraSample.screen,
                                                 screenSample.ray, rng);
    screenSample.rgb = screenSample.rgb + min(sample.rgb, make_vec3f(self->maxRadiance));
    screenSample.alpha = screenSample.alpha + sample.alpha;
    screenSample.z = min(screenSample.z, sample.z);
  }

  screenSample.rgb = screenSample.rgb * rcpf(spp);
  screenSample.alpha = screenSample.alpha * rcpf(spp);
  return screenSample;
}




unmasked void *uniform PathTracer_beginFrame(uniform Renderer *uniform _self,
                                    uniform FrameBuffer *uniform fb)
{
  _self->fb = fb;
  return NULL;
}


void PathTracer_renderTileJob(uniform PathTracer *uniform self,
                              uniform Tile &tile,
                              uniform int taskIndex)
{
  uniform FrameBuffer *uniform fb = self->super.fb;

  uniform int32 spp = self->super.spp;
  const uniform int blocks = tile.accumID > 0 || spp > 0 ?
                               1 : min(1 << -2 * spp, TILE_SIZE*TILE_SIZE);

  const uniform int begin = taskIndex * RENDERTILE_PIXELS_PER_JOB;
  const uniform int end   = min(begin + RENDERTILE_PIXELS_PER_JOB, TILE_SIZE*TILE_SIZE/blocks);

  for (uint32 i=begin+programIndex;i<end;i+=programCount) {
    const uint32 ix = tile.region.lower.x + z_order.xs[i*blocks];
    const uint32 iy = tile.region.lower.y + z_order.ys[i*blocks];
    if (ix >= fb->size.x || iy >= fb->size.y)
      continue;

    ScreenSample screenSample = PathTracer_renderPixel(self, ix, iy, tile.accumID);

    for (uniform int p = 0; p < blocks; p++) {
      const uint32 pixel = z_order.xs[i*blocks+p] + (z_order.ys[i*blocks+p] * TILE_SIZE);
      setRGBAZ(tile, pixel, screenSample.rgb, screenSample.alpha, screenSample.z);
    }
  }
}

unmasked void PathTracer_renderTile(uniform Renderer *uniform _self,
                           void *uniform perFrameData,
                           uniform Tile &tile,
                           uniform int jobID)
{
  uniform PathTracer *uniform self = (uniform PathTracer *uniform)_self;

  PathTracer_renderTileJob(self, tile, jobID);
}


// Exports (called from C++)
//////////////////////////////////////////////////////////////////////////////

export void PathTracer_set(void *uniform _self,
                           const uniform int32 maxDepth,
                           const uniform float minContribution,
                           const uniform float maxRadiance,
                           void *uniform backplate,
                           void **uniform lights,
                           const uniform uint32 numLights)
{
  uniform PathTracer *uniform self = (uniform PathTracer *uniform)_self;

  self->maxDepth = maxDepth;
  self->minContribution = minContribution;
  self->maxRadiance = maxRadiance;
  self->backplate = (uniform Texture2D *uniform)backplate;
  self->lights = (const uniform Light *uniform *uniform)lights;
  self->numLights = numLights;
}

export void* uniform PathTracer_create(void *uniform cppE)
{
  uniform PathTracer *uniform self = uniform new uniform PathTracer;
  Renderer_Constructor(&self->super,cppE);
  self->super.renderTile   = PathTracer_renderTile;
  self->super.beginFrame   = PathTracer_beginFrame;

  PathTracer_set(self, 20, 0.01f, inf, NULL, NULL, 0);

  precomputeZOrder();

  return self;
}
