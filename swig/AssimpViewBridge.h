#pragma once

#define ASSIMP_VIEW_SWIG_INTERFACE_VERSION 1

namespace AssimpViewMaui {

/**
 * Public, ownership-safe facade for the native viewer and the Assimp scene
 * data used by it.  Assimp types stay opaque here so Assimp.View.MAUI can be
 * consumed together with Assimp.MAUI without generating duplicate C# types.
 */
class AssimpView {
public:
    /** @brief Creates a reusable Assimp View instance. */
    AssimpView();
    /** @brief Releases the native Assimp View instance. */
    ~AssimpView();

    /** @brief Creates the native rendering window and graphics context. */
    bool Initialize(int width, int height);
    /** @brief Loads an asset using the viewer's default post-process flags. */
    bool LoadAsset(const char *path);
    /** @brief Loads an asset using explicit Assimp post-process flags. */
    bool LoadAssetWithPostProcess(const char *path, unsigned int flags);
    /** @brief Processes events and renders one frame. */
    bool Frame();
    /** @brief Resizes the native rendering surface. */
    void Resize(int width, int height);
    /** @brief Releases the native rendering resources. */
    void Shutdown();
    /** @brief Releases the separately owned Assimp scene snapshot. */
    void ReleaseAsset();
    /** @brief Reports whether the viewer currently has a model. */
    bool HasModel() const;
    /** @brief Reports whether the Assimp scene snapshot is available. */
    bool HasScene() const;
    /** @brief Returns the last native load error, if any. */
    const char *GetLastError() const;

    /** @name Scene and asset inspection */
    ///@{
    unsigned int GetMeshCount() const;
    unsigned int GetMaterialCount() const;
    unsigned int GetAnimationCount() const;
    unsigned int GetTextureCount() const;
    unsigned int GetLightCount() const;
    unsigned int GetCameraCount() const;
    const char *GetRootNodeName() const;
    unsigned int GetRootNodeChildCount() const;
    unsigned int GetRootNodeMeshCount() const;
    unsigned int GetRootNodeMeshIndex(unsigned int index) const;
    float GetRootNodeTransformElement(unsigned int row, unsigned int column) const;
    ///@}

    /** @name Animation inspection and playback state */
    ///@{
    const char *GetAnimationName(unsigned int animationIndex) const;
    double GetAnimationDuration(unsigned int animationIndex) const;
    double GetAnimationTicksPerSecond(unsigned int animationIndex) const;
    double GetAnimationDurationInSeconds(unsigned int animationIndex) const;
    unsigned int GetAnimationChannelCount(unsigned int animationIndex) const;
    const char *GetAnimationChannelName(unsigned int animationIndex, unsigned int channelIndex) const;
    unsigned int GetAnimationChannelPositionKeyCount(unsigned int animationIndex, unsigned int channelIndex) const;
    unsigned int GetAnimationChannelRotationKeyCount(unsigned int animationIndex, unsigned int channelIndex) const;
    unsigned int GetAnimationChannelScalingKeyCount(unsigned int animationIndex, unsigned int channelIndex) const;
    double GetAnimationChannelPositionKeyTime(unsigned int animationIndex, unsigned int channelIndex, unsigned int keyIndex) const;
    float GetAnimationChannelPositionKeyComponent(unsigned int animationIndex, unsigned int channelIndex, unsigned int keyIndex, unsigned int component) const;
    double GetAnimationChannelRotationKeyTime(unsigned int animationIndex, unsigned int channelIndex, unsigned int keyIndex) const;
    float GetAnimationChannelRotationKeyComponent(unsigned int animationIndex, unsigned int channelIndex, unsigned int keyIndex, unsigned int component) const;
    double GetAnimationChannelScalingKeyTime(unsigned int animationIndex, unsigned int channelIndex, unsigned int keyIndex) const;
    float GetAnimationChannelScalingKeyComponent(unsigned int animationIndex, unsigned int channelIndex, unsigned int keyIndex, unsigned int component) const;
    bool SetAnimationTime(unsigned int animationIndex, double timeInTicks);
    unsigned int GetActiveAnimation() const;
    double GetAnimationTime() const;
    ///@}

    /** @name Assimp build information */
    ///@{
    static unsigned int GetAssimpVersionMajor();
    static unsigned int GetAssimpVersionMinor();
    static unsigned int GetAssimpVersionRevision();
    static unsigned int GetAssimpCompileFlags();
    static const char *GetAssimpLegalString();
    /** @brief Returns the version of this package's SWIG facade contract. */
    static unsigned int GetSwigInterfaceVersion();
    ///@}

private:
    class Impl;
    Impl *m_impl;
};

} // namespace AssimpViewMaui
