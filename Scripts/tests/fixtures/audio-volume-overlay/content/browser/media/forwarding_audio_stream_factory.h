// Upstream excerpts holding the DEV-800 overlay anchors (Chromium 157.0.8103.78).

    // Sets the muting state for all output streams created through this
    // factory.
    void SetMuted(bool muted);

    void ResetRemoteFactoryPtrIfIdle();
    void ResetRemoteFactoryPtr();

    std::optional<AudioMutingSession> muter_;

  // Returns the current muting state.
  bool IsMuted() const;

  bool is_muted_ = false;
