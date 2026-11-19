%module AssimpViewModule

/* Keep the SWIG conventions used by Assimp.MAUI: Doxygen comments are
 * preserved, standard integer/typemap support is available, and the generated
 * C# namespace is supplied by each platform build script. */
%include "stdint.i"
%include "typemaps.i"

%constant unsigned int AssimpViewSwigInterfaceVersion = 1;

%{
#include "AssimpViewBridge.h"
%}

/* The facade deliberately exposes primitive/opaque scene data instead of
 * importing Assimp's C++ structs a second time. Assimp.MAUI remains the owner
 * of aiScene/aiAnimation bindings, while this package exposes every viewer
 * operation and the animation inspection needed by the control. */
%include "AssimpViewBridge.h"
