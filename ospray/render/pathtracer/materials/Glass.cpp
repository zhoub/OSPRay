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

#include "ospray/common/Material.h"
#include "Glass_ispc.h"

namespace ospray {
  namespace pathtracer {
    struct Glass : public ospray::Material {
      //! \brief common function to help printf-debugging
      /*! Every derived class should overrride this! */
      virtual std::string toString() const { return "ospray::pathtracer::Glass"; }

      //! \brief commit the material's parameters
      virtual void commit() {
        if (getIE() != NULL) return;

        const vec3f& transmissionInside
          = getParam3f("transmissionInside",vec3f(1.f));
        const vec3f& transmissionOutside
          = getParam3f("transmissionOutside",vec3f(1.f));

         // std::cout << "transmission = " << transmissionInside.x << " " << transmissionInside.y << " " << transmissionInside.z << "\n";

        const float etaInside = getParamf("etaInside", getParamf("eta", 1.5f));
        const float etaOutside = getParamf("etaOutside", 1.f);

        //const vec3f& absorptionColor = getParam3f("absorptionColor",vec3f(1.0f));
        const float absorptionDistance = getParamf("absorptionDistance", 0.0f);

        // Why is "absorptionColor" not found, while "color" is found???
        const vec3f& absorptionColor = getParam3f("color",vec3f(1.f));

        //std::cout << "absCol = " << absorptionColor.x << " " << absorptionColor.y << " " << absorptionColor.z << ", absDist = " << absorptionDistance << "\n\n";

        ispcEquivalent = ispc::PathTracer_Glass_create
          (etaInside, (const ispc::vec3f&)transmissionInside,
           etaOutside, (const ispc::vec3f&)transmissionOutside,
           absorptionDistance, (const ispc::vec3f&)absorptionColor);
      }
    };




    OSP_REGISTER_MATERIAL(Glass,PathTracer_Glass);
  }
}
