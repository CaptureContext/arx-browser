// Upstream excerpts holding the DEV-800 overlay anchors (Chromium 157.0.8103.78).

void ForwardingAudioStreamFactory::Core::AddLoopbackSink(

    // Restore the muting session on reconnect.
    if (muter_) {
      muter_->Connect(remote_factory_.get());
    }

bool ForwardingAudioStreamFactory::IsMuted() const {
