#include "App/App.h"
#include "RenderBackend/RenderBackendService.h"
#include "RenderBackend/TransformMatrixBlock.h"

/* ModelLoadingApp::importAsset is protected upstream. The prerequisite OSRE
 * headers are included first, so this narrow access shim never macroizes the
 * STL or changes the ABI of OSRE itself. */
#define protected public
#include "ModelLoadingApp.h"
#undef protected

#include "AssimpViewBridge.h"
#include "IO/Uri.h"

#include <assimp/cimport.h>
#include <assimp/postprocess.h>
#include <assimp/scene.h>
#include <assimp/version.h>

#include <cstring>

namespace AssimpViewMaui {

namespace {

constexpr unsigned int kDefaultPostProcess =
    aiProcess_Triangulate |
    aiProcess_JoinIdenticalVertices |
    aiProcess_GenSmoothNormals;

const aiAnimation *GetAnimation(const aiScene *scene, unsigned int index) {
    return scene != nullptr && index < scene->mNumAnimations && scene->mAnimations != nullptr
        ? scene->mAnimations[index]
        : nullptr;
}

const aiNodeAnim *GetChannel(const aiAnimation *animation, unsigned int index) {
    return animation != nullptr && index < animation->mNumChannels && animation->mChannels != nullptr
        ? animation->mChannels[index]
        : nullptr;
}

const aiNode *GetRootNode(const aiScene *scene) {
    return scene == nullptr ? nullptr : scene->mRootNode;
}

} // namespace

class AssimpView::Impl {
public:
    char arg0[16];
    char *argv[2];
    ModelLoadingApp app;
    const aiScene *scene;
    bool initialized;
    unsigned int activeAnimation;
    double animationTime;
    char lastError[256];

    Impl()
        : arg0{}, argv{arg0, nullptr}, app(1, argv), scene(nullptr),
          initialized(false), activeAnimation(static_cast<unsigned int>(-1)),
          animationTime(0.0), lastError{} {
        const char name[] = "AssimpView";
        for (unsigned int i = 0; name[i] != '\0' && i + 1 < sizeof(arg0); ++i) {
            arg0[i] = name[i];
        }
    }

    void setError(const char *message) {
        if (message == nullptr) {
            lastError[0] = '\0';
            return;
        }
        std::strncpy(lastError, message, sizeof(lastError) - 1);
        lastError[sizeof(lastError) - 1] = '\0';
    }

    void releaseScene() {
        if (scene != nullptr) {
            aiReleaseImport(scene);
            scene = nullptr;
        }
        activeAnimation = static_cast<unsigned int>(-1);
        animationTime = 0.0;
    }
};

AssimpView::AssimpView() : m_impl(new Impl) {}

AssimpView::~AssimpView() {
    Shutdown();
    delete m_impl;
    m_impl = nullptr;
}

bool AssimpView::Initialize(int width, int height) {
    if (m_impl == nullptr || m_impl->initialized) {
        return m_impl != nullptr;
    }
    m_impl->initialized = m_impl->app.initWindow(
        0, 0, static_cast<OSRE::ui32>(width), static_cast<OSRE::ui32>(height),
        "Assimp View", OSRE::App::WindowMode::Windowed,
        OSRE::App::WindowType::Root,
        OSRE::App::RenderBackendType::OpenGLRenderBackend);
    return m_impl->initialized;
}

bool AssimpView::LoadAsset(const char *path) {
    return LoadAssetWithPostProcess(path, kDefaultPostProcess);
}

bool AssimpView::LoadAssetWithPostProcess(const char *path, unsigned int flags) {
    if (m_impl == nullptr || !m_impl->initialized || path == nullptr) {
        return false;
    }

    OSRE::IO::Uri uri{OSRE::String(path)};
    if (!uri.isValid()) {
        m_impl->setError("The asset path is not a valid URI.");
        return false;
    }

    m_impl->releaseScene();
    m_impl->app.importAsset(uri);
    m_impl->scene = aiImportFile(path, flags);
    if (m_impl->scene == nullptr) {
        m_impl->setError("Assimp could not import the asset.");
        return false;
    }
    m_impl->setError(nullptr);
    return m_impl->app.hasModel();
}

bool AssimpView::Frame() {
    if (m_impl == nullptr || !m_impl->initialized || !m_impl->app.handleEvents()) {
        return false;
    }
    m_impl->app.update();
    m_impl->app.requestNextFrame();
    return true;
}

void AssimpView::Resize(int width, int height) {
    if (m_impl != nullptr && m_impl->initialized) {
        m_impl->app.resize(0, 0, width, height);
    }
}

void AssimpView::Shutdown() {
    if (m_impl != nullptr) {
        m_impl->releaseScene();
        if (m_impl->initialized) {
            m_impl->app.destroy();
            m_impl->initialized = false;
        }
    }
}

void AssimpView::ReleaseAsset() {
    if (m_impl != nullptr) {
        m_impl->releaseScene();
    }
}

bool AssimpView::HasModel() const {
    return m_impl != nullptr && m_impl->app.hasModel();
}

bool AssimpView::HasScene() const {
    return m_impl != nullptr && m_impl->scene != nullptr;
}

const char *AssimpView::GetLastError() const {
    return m_impl == nullptr ? "Assimp View is not initialized." : m_impl->lastError;
}

unsigned int AssimpView::GetMeshCount() const { return m_impl != nullptr && m_impl->scene != nullptr ? m_impl->scene->mNumMeshes : 0; }
unsigned int AssimpView::GetMaterialCount() const { return m_impl != nullptr && m_impl->scene != nullptr ? m_impl->scene->mNumMaterials : 0; }
unsigned int AssimpView::GetAnimationCount() const { return m_impl != nullptr && m_impl->scene != nullptr ? m_impl->scene->mNumAnimations : 0; }
unsigned int AssimpView::GetTextureCount() const { return m_impl != nullptr && m_impl->scene != nullptr ? m_impl->scene->mNumTextures : 0; }
unsigned int AssimpView::GetLightCount() const { return m_impl != nullptr && m_impl->scene != nullptr ? m_impl->scene->mNumLights : 0; }
unsigned int AssimpView::GetCameraCount() const { return m_impl != nullptr && m_impl->scene != nullptr ? m_impl->scene->mNumCameras : 0; }

const char *AssimpView::GetRootNodeName() const {
    const aiNode *root = GetRootNode(m_impl == nullptr ? nullptr : m_impl->scene);
    return root == nullptr ? "" : root->mName.C_Str();
}

unsigned int AssimpView::GetRootNodeChildCount() const {
    const aiNode *root = GetRootNode(m_impl == nullptr ? nullptr : m_impl->scene);
    return root == nullptr ? 0 : root->mNumChildren;
}

unsigned int AssimpView::GetRootNodeMeshCount() const {
    const aiNode *root = GetRootNode(m_impl == nullptr ? nullptr : m_impl->scene);
    return root == nullptr ? 0 : root->mNumMeshes;
}

unsigned int AssimpView::GetRootNodeMeshIndex(unsigned int index) const {
    const aiNode *root = GetRootNode(m_impl == nullptr ? nullptr : m_impl->scene);
    return root != nullptr && root->mMeshes != nullptr && index < root->mNumMeshes
        ? root->mMeshes[index]
        : static_cast<unsigned int>(-1);
}

float AssimpView::GetRootNodeTransformElement(unsigned int row, unsigned int column) const {
    const aiNode *root = GetRootNode(m_impl == nullptr ? nullptr : m_impl->scene);
    if (root == nullptr || row >= 4 || column >= 4) {
        return 0.0f;
    }
    const float *values = &root->mTransformation.a1;
    return values[row * 4 + column];
}

const char *AssimpView::GetAnimationName(unsigned int animationIndex) const {
    const aiAnimation *animation = GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex);
    return animation == nullptr ? "" : animation->mName.C_Str();
}

double AssimpView::GetAnimationDuration(unsigned int animationIndex) const {
    const aiAnimation *animation = GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex);
    return animation == nullptr ? 0.0 : animation->mDuration;
}

double AssimpView::GetAnimationTicksPerSecond(unsigned int animationIndex) const {
    const aiAnimation *animation = GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex);
    return animation == nullptr ? 0.0 : animation->mTicksPerSecond;
}

double AssimpView::GetAnimationDurationInSeconds(unsigned int animationIndex) const {
    const aiAnimation *animation = GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex);
    return animation != nullptr && animation->mTicksPerSecond > 0.0
        ? animation->mDuration / animation->mTicksPerSecond
        : 0.0;
}

unsigned int AssimpView::GetAnimationChannelCount(unsigned int animationIndex) const {
    const aiAnimation *animation = GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex);
    return animation == nullptr ? 0 : animation->mNumChannels;
}

const char *AssimpView::GetAnimationChannelName(unsigned int animationIndex, unsigned int channelIndex) const {
    const aiNodeAnim *channel = GetChannel(GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex), channelIndex);
    return channel == nullptr ? "" : channel->mNodeName.C_Str();
}

unsigned int AssimpView::GetAnimationChannelPositionKeyCount(unsigned int animationIndex, unsigned int channelIndex) const {
    const aiNodeAnim *channel = GetChannel(GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex), channelIndex);
    return channel == nullptr ? 0 : channel->mNumPositionKeys;
}

unsigned int AssimpView::GetAnimationChannelRotationKeyCount(unsigned int animationIndex, unsigned int channelIndex) const {
    const aiNodeAnim *channel = GetChannel(GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex), channelIndex);
    return channel == nullptr ? 0 : channel->mNumRotationKeys;
}

unsigned int AssimpView::GetAnimationChannelScalingKeyCount(unsigned int animationIndex, unsigned int channelIndex) const {
    const aiNodeAnim *channel = GetChannel(GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex), channelIndex);
    return channel == nullptr ? 0 : channel->mNumScalingKeys;
}

double AssimpView::GetAnimationChannelPositionKeyTime(unsigned int animationIndex, unsigned int channelIndex, unsigned int keyIndex) const {
    const aiNodeAnim *channel = GetChannel(GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex), channelIndex);
    return channel != nullptr && channel->mPositionKeys != nullptr && keyIndex < channel->mNumPositionKeys ? channel->mPositionKeys[keyIndex].mTime : 0.0;
}

float AssimpView::GetAnimationChannelPositionKeyComponent(unsigned int animationIndex, unsigned int channelIndex, unsigned int keyIndex, unsigned int component) const {
    const aiNodeAnim *channel = GetChannel(GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex), channelIndex);
    return channel != nullptr && channel->mPositionKeys != nullptr && keyIndex < channel->mNumPositionKeys && component < 3 ? channel->mPositionKeys[keyIndex].mValue[component] : 0.0f;
}

double AssimpView::GetAnimationChannelRotationKeyTime(unsigned int animationIndex, unsigned int channelIndex, unsigned int keyIndex) const {
    const aiNodeAnim *channel = GetChannel(GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex), channelIndex);
    return channel != nullptr && channel->mRotationKeys != nullptr && keyIndex < channel->mNumRotationKeys ? channel->mRotationKeys[keyIndex].mTime : 0.0;
}

float AssimpView::GetAnimationChannelRotationKeyComponent(unsigned int animationIndex, unsigned int channelIndex, unsigned int keyIndex, unsigned int component) const {
    const aiNodeAnim *channel = GetChannel(GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex), channelIndex);
    if (channel == nullptr || channel->mRotationKeys == nullptr || keyIndex >= channel->mNumRotationKeys || component >= 4) return 0.0f;
    const aiQuaternion &value = channel->mRotationKeys[keyIndex].mValue;
    switch (component) { case 0: return value.w; case 1: return value.x; case 2: return value.y; default: return value.z; }
}

double AssimpView::GetAnimationChannelScalingKeyTime(unsigned int animationIndex, unsigned int channelIndex, unsigned int keyIndex) const {
    const aiNodeAnim *channel = GetChannel(GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex), channelIndex);
    return channel != nullptr && channel->mScalingKeys != nullptr && keyIndex < channel->mNumScalingKeys ? channel->mScalingKeys[keyIndex].mTime : 0.0;
}

float AssimpView::GetAnimationChannelScalingKeyComponent(unsigned int animationIndex, unsigned int channelIndex, unsigned int keyIndex, unsigned int component) const {
    const aiNodeAnim *channel = GetChannel(GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex), channelIndex);
    return channel != nullptr && channel->mScalingKeys != nullptr && keyIndex < channel->mNumScalingKeys && component < 3 ? channel->mScalingKeys[keyIndex].mValue[component] : 0.0f;
}

bool AssimpView::SetAnimationTime(unsigned int animationIndex, double timeInTicks) {
    if (GetAnimation(m_impl == nullptr ? nullptr : m_impl->scene, animationIndex) == nullptr) {
        return false;
    }
    m_impl->activeAnimation = animationIndex;
    m_impl->animationTime = timeInTicks;
    return true;
}

unsigned int AssimpView::GetActiveAnimation() const { return m_impl == nullptr ? static_cast<unsigned int>(-1) : m_impl->activeAnimation; }
double AssimpView::GetAnimationTime() const { return m_impl == nullptr ? 0.0 : m_impl->animationTime; }

unsigned int AssimpView::GetAssimpVersionMajor() { return aiGetVersionMajor(); }
unsigned int AssimpView::GetAssimpVersionMinor() { return aiGetVersionMinor(); }
unsigned int AssimpView::GetAssimpVersionRevision() { return aiGetVersionRevision(); }
unsigned int AssimpView::GetAssimpCompileFlags() { return aiGetCompileFlags(); }
const char *AssimpView::GetAssimpLegalString() { return aiGetLegalString(); }
unsigned int AssimpView::GetSwigInterfaceVersion() { return ASSIMP_VIEW_SWIG_INTERFACE_VERSION; }

} // namespace AssimpViewMaui
