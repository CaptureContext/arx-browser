"""Per-tab volume (DEV-800): a group gain on the audio service's output streams.

Chromium mutes a WebContents through its audio group: the browser binds a
LocalMuter in the audio service, and every OutputController in the group stops
local playout. This adds the same for volume. The browser binds an
ArxLocalVolume for the group and sets it in [0, 1]; each OutputController
multiplies its stream volume (the page's own, from the renderer) by it. Every
player shares that path, WebRTC included, so a Google Meet tab turns down as a
video does. Snoopers keep the unscaled signal, as with muting.

`WebContents::SetAudioVolume` is the public entry; Arx calls it from the
exported `ArxEngineSetPageAudioVolume`, outside the ABI table, so the app runs
on engines built before it. Anchors fail closed against the pinned Chromium.
New audio service code lives in whole files that every application rewrites.
"""

import shutil


def apply(source):
    from .config import PACKAGE
    from .overlay import replace_once

    # The mojo contract: a group volume beside the group muter.
    mojom = source / "media/mojo/mojom/audio_stream_factory.mojom"
    replace_once(mojom, "interface LocalMuter {};", """interface LocalMuter {};

// Arx: scales local playout of a group of AudioOutputStreams by the last
// volume, in [0, 1], while at least one binding exists. Once the last binding
// is dropped, the group's streams play at full volume again.
interface LocalVolume {
  SetVolume(double volume);
};""")
    replace_once(mojom, """  BindMuter(pending_associated_receiver<LocalMuter> receiver,
            mojo_base.mojom.UnguessableToken group_id);""", """  BindMuter(pending_associated_receiver<LocalMuter> receiver,
            mojo_base.mojom.UnguessableToken group_id);

  // Arx: binds the request to the LocalVolume of the given |group_id|, as
  // BindMuter does for muting.
  BindVolume(pending_associated_receiver<LocalVolume> receiver,
             mojo_base.mojom.UnguessableToken group_id);""")

    # Group members take the gain; only OutputController plays locally.
    muteable = source / "services/audio/muteable.h"
    replace_once(muteable, "  virtual void StopMuting() = 0;", """  virtual void StopMuting() = 0;

  // Arx: scales the outbound audio by |volume| in [0, 1], on top of the
  // stream's own volume. Snoopers still get the original audio.
  virtual void SetGroupVolume(double volume) {}""")

    controller_header = source / "services/audio/output_controller.h"
    replace_once(controller_header, "  void StopMuting() override;", """  void StopMuting() override;
  void SetGroupVolume(double volume) override;""")
    replace_once(controller_header, """  // The current volume of the audio stream.
  double volume_;""", """  // The current volume of the audio stream.
  double volume_;

  // Arx: the group's volume, which scales |volume_| for local playout only.
  double group_volume_ = 1.0;""")

    controller = source / "services/audio/output_controller.cc"
    replace_once(controller, """  // We have successfully opened the stream. Set the initial volume.
  stream_->SetVolume(volume_);""", """  // We have successfully opened the stream. Set the initial volume.
  stream_->SetVolume(volume_ * group_volume_);""")
    replace_once(controller, """    case kPaused:
      stream_->SetVolume(volume_);
      break;""", """    case kPaused:
      stream_->SetVolume(volume_ * group_volume_);
      break;""")
    replace_once(controller, "void OutputController::StopMuting() {", """void OutputController::SetGroupVolume(double volume) {
  DCHECK(task_runner_->BelongsToCurrentThread());
  group_volume_ = std::clamp(volume, 0.0, 1.0);
  // Applies the stream's own volume again, now scaled by the group's.
  SetVolume(volume_);
}

void OutputController::StopMuting() {""")

    # The service side: one ArxLocalVolume per group, kept while it's bound.
    audio = source / "services/audio"
    for name in ["arx_local_volume.h", "arx_local_volume.cc"]:
        shutil.copy2(PACKAGE / "Native/audio_volume" / name, audio / name)
    replace_once(audio / "BUILD.gn", """    "local_muter.cc",
    "local_muter.h",
""", """    "arx_local_volume.cc",
    "arx_local_volume.h",
    "local_muter.cc",
    "local_muter.h",
""")

    factory_header = audio / "stream_factory.h"
    replace_once(factory_header, "class LocalMuter;", "class ArxLocalVolume;\nclass LocalMuter;")
    replace_once(factory_header, """  void BindMuter(
      mojo::PendingAssociatedReceiver<media::mojom::LocalMuter> receiver,
      const base::UnguessableToken& group_id) final;""", """  void BindMuter(
      mojo::PendingAssociatedReceiver<media::mojom::LocalMuter> receiver,
      const base::UnguessableToken& group_id) final;
  void BindVolume(
      mojo::PendingAssociatedReceiver<media::mojom::LocalVolume> receiver,
      const base::UnguessableToken& group_id) final;""")
    replace_once(factory_header, "  void DestroyMuter(base::WeakPtr<LocalMuter> muter);", """  void DestroyMuter(base::WeakPtr<LocalMuter> muter);
  void DestroyVolume(base::WeakPtr<ArxLocalVolume> volume);""")
    replace_once(factory_header, "  std::vector<std::unique_ptr<LocalMuter>> muters_;", """  std::vector<std::unique_ptr<LocalMuter>> muters_;
  std::vector<std::unique_ptr<ArxLocalVolume>> volumes_;""")

    factory = audio / "stream_factory.cc"
    replace_once(factory, '#include "services/audio/local_muter.h"',
                 '#include "services/audio/arx_local_volume.h"\n#include "services/audio/local_muter.h"')
    replace_once(factory, "void StreamFactory::CreateLoopbackStream(", """void StreamFactory::BindVolume(
    mojo::PendingAssociatedReceiver<media::mojom::LocalVolume> receiver,
    const base::UnguessableToken& group_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(owning_sequence_);

  auto it = std::ranges::find(volumes_, group_id, &ArxLocalVolume::group_id);
  ArxLocalVolume* volume;
  if (it == volumes_.end()) {
    auto volume_ptr = std::make_unique<ArxLocalVolume>(&coordinator_, group_id);
    volume = volume_ptr.get();
    volume->SetAllBindingsLostCallback(
        base::BindRepeating(&StreamFactory::DestroyVolume,
                            base::Unretained(this), volume_ptr->GetWeakPtr()));
    volumes_.emplace_back(std::move(volume_ptr));
  } else {
    volume = it->get();
  }
  volume->AddReceiver(std::move(receiver));
}

void StreamFactory::DestroyVolume(base::WeakPtr<ArxLocalVolume> volume) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(owning_sequence_);
  if (!volume) {
    return;
  }

  // Posted for the same reason as DestroyMuter: streams destroyed in the same
  // batch of messages go first, so none plays a moment at full volume.
  auto do_destroy = [](base::WeakPtr<StreamFactory> weak_this,
                       base::WeakPtr<ArxLocalVolume> volume) {
    if (weak_this && volume && !volume->HasReceivers()) {
      std::erase_if(weak_this->volumes_, base::MatchesUniquePtr(volume.get()));
    }
  };
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(do_destroy, weak_ptr_factory_.GetWeakPtr(), volume));
}

void StreamFactory::CreateLoopbackStream(""")

    # Every other AudioStreamFactory: a fake ignores it, TTS refuses it like BindMuter.
    fake = audio / "public/cpp/fake_stream_factory.h"
    replace_once(fake, """  void BindMuter(
      mojo::PendingAssociatedReceiver<media::mojom::LocalMuter> receiver,
      const base::UnguessableToken& group_id) override {}""", """  void BindMuter(
      mojo::PendingAssociatedReceiver<media::mojom::LocalMuter> receiver,
      const base::UnguessableToken& group_id) override {}
  void BindVolume(
      mojo::PendingAssociatedReceiver<media::mojom::LocalVolume> receiver,
      const base::UnguessableToken& group_id) override {}""")
    tts_header = source / "chrome/browser/speech/extension_api/tts_audio_output_stream_factory.h"
    replace_once(tts_header, """  void BindMuter(
      mojo::PendingAssociatedReceiver<media::mojom::LocalMuter> receiver,
      const base::UnguessableToken& group_id) override;""", """  void BindMuter(
      mojo::PendingAssociatedReceiver<media::mojom::LocalMuter> receiver,
      const base::UnguessableToken& group_id) override;
  void BindVolume(
      mojo::PendingAssociatedReceiver<media::mojom::LocalVolume> receiver,
      const base::UnguessableToken& group_id) override;""")
    tts = source / "chrome/browser/speech/extension_api/tts_audio_output_stream_factory.cc"
    replace_once(tts, "void TtsAudioOutputStreamFactory::BindMuter(", """void TtsAudioOutputStreamFactory::BindVolume(
    mojo::PendingAssociatedReceiver<media::mojom::LocalVolume> receiver,
    const base::UnguessableToken& group_id) {
  mojo::ReportBadMessage("TtsAudioOutputStreamFactory: BindVolume is rejected");
}

void TtsAudioOutputStreamFactory::BindMuter(""")
    for name in ["forwarding_audio_stream_factory_unittest.cc", "audio_loopback_stream_broker_unittest.cc"]:
        replace_once(source / "content/browser/media" / name, "  void BindMuter(\n", """  void BindVolume(
      mojo::PendingAssociatedReceiver<media::mojom::LocalVolume> receiver,
      const base::UnguessableToken& group_id) override {}
  void BindMuter(
""")

    # The browser side: each WebContents' factory keeps its volume and binds it
    # whenever it connects to the audio service, as it does its muter.
    forwarding_header = source / "content/browser/media/forwarding_audio_stream_factory.h"
    replace_once(forwarding_header, """    // Sets the muting state for all output streams created through this
    // factory.
    void SetMuted(bool muted);""", """    // Sets the muting state for all output streams created through this
    // factory.
    void SetMuted(bool muted);

    // Arx: scales local playout of all output streams created through this
    // factory by |volume| in [0, 1].
    void SetVolume(double volume);""")
    replace_once(forwarding_header, """    void ResetRemoteFactoryPtrIfIdle();
    void ResetRemoteFactoryPtr();""", """    void ResetRemoteFactoryPtrIfIdle();
    void ResetRemoteFactoryPtr();
    void ConnectVolume();""")
    replace_once(forwarding_header, """    std::optional<AudioMutingSession> muter_;""", """    std::optional<AudioMutingSession> muter_;

    // Arx: the group's volume, bound in the service only below 1.
    double volume_ = 1.0;
    mojo::AssociatedRemote<media::mojom::LocalVolume> volume_remote_;""")
    replace_once(forwarding_header, """  // Returns the current muting state.
  bool IsMuted() const;""", """  // Returns the current muting state.
  bool IsMuted() const;

  // Arx: scales local playout of all output streams created through this
  // factory by |volume| in [0, 1], and returns it.
  void SetVolume(double volume);
  double GetVolume() const;""")
    replace_once(forwarding_header, "  bool is_muted_ = false;", "  bool is_muted_ = false;\n  double volume_ = 1.0;")

    forwarding = source / "content/browser/media/forwarding_audio_stream_factory.cc"
    replace_once(forwarding, "void ForwardingAudioStreamFactory::Core::AddLoopbackSink(", """void ForwardingAudioStreamFactory::Core::SetVolume(double volume) {
  CHECK_CURRENTLY_ON(BrowserThread::IO, base::NotFatalUntil::M160);
  volume_ = volume;
  if (volume_remote_.is_bound() && volume_remote_.is_connected()) {
    volume_remote_->SetVolume(volume_);
    return;
  }
  ConnectVolume();
}

void ForwardingAudioStreamFactory::Core::ConnectVolume() {
  CHECK_CURRENTLY_ON(BrowserThread::IO, base::NotFatalUntil::M160);
  volume_remote_.reset();
  // Like muting, volume never opens the connection; GetFactory() restores it.
  if (!remote_factory_ || volume_ == 1.0) {
    return;
  }
  remote_factory_->BindVolume(volume_remote_.BindNewEndpointAndPassReceiver(),
                              group_id_);
  volume_remote_->SetVolume(volume_);
}

void ForwardingAudioStreamFactory::Core::AddLoopbackSink(""")
    replace_once(forwarding, """    // Restore the muting session on reconnect.
    if (muter_) {
      muter_->Connect(remote_factory_.get());
    }""", """    // Restore the muting session on reconnect.
    if (muter_) {
      muter_->Connect(remote_factory_.get());
    }
    ConnectVolume();""")
    replace_once(forwarding, "bool ForwardingAudioStreamFactory::IsMuted() const {", """void ForwardingAudioStreamFactory::SetVolume(double volume) {
  CHECK_CURRENTLY_ON(BrowserThread::UI, base::NotFatalUntil::M160);
  if (volume_ == volume) {
    return;
  }
  volume_ = volume;
  // Unretained is safe since the destruction of |core_| will be posted to the
  // IO thread later.
  GetIOThreadTaskRunner({})->PostTask(
      FROM_HERE,
      base::BindOnce(&Core::SetVolume, base::Unretained(core_.get()), volume));
}

double ForwardingAudioStreamFactory::GetVolume() const {
  CHECK_CURRENTLY_ON(BrowserThread::UI, base::NotFatalUntil::M160);
  return volume_;
}

bool ForwardingAudioStreamFactory::IsMuted() const {""")

    web_contents = source / "content/public/browser/web_contents.h"
    replace_once(web_contents, "  virtual void SetAudioMuted(bool mute) = 0;", """  virtual void SetAudioMuted(bool mute) = 0;

  // Arx: scales this WebContents' local audio output by |volume| in [0, 1],
  // on top of each player's own volume, for every stream it plays now or
  // later. Muting still wins; capture still gets the unscaled audio.
  virtual void SetAudioVolume(double volume) {}
  virtual double GetAudioVolume() { return 1.0; }""")
    impl_header = source / "content/browser/web_contents/web_contents_impl.h"
    replace_once(impl_header, "  void SetAudioMuted(bool mute) override;", """  void SetAudioMuted(bool mute) override;
  void SetAudioVolume(double volume) override;
  double GetAudioVolume() override;""")
    impl = source / "content/browser/web_contents/web_contents_impl.cc"
    replace_once(impl, "bool WebContentsImpl::IsCurrentlyAudible() {", """void WebContentsImpl::SetAudioVolume(double volume) {
  if (!std::isfinite(volume)) {
    return;
  }
  GetAudioStreamFactory()->SetVolume(std::clamp(volume, 0.0, 1.0));
}

double WebContentsImpl::GetAudioVolume() {
  return audio_stream_factory_ ? audio_stream_factory_->GetVolume() : 1.0;
}

bool WebContentsImpl::IsCurrentlyAudible() {""")
