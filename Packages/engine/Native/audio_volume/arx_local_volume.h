// Arx (DEV-800). Copied to services/audio by Scripts/engine/audio_volume_overlay.py.

#ifndef SERVICES_AUDIO_ARX_LOCAL_VOLUME_H_
#define SERVICES_AUDIO_ARX_LOCAL_VOLUME_H_

#include <memory>

#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/sequence_checker.h"
#include "base/unguessable_token.h"
#include "media/mojo/mojom/audio_stream_factory.mojom.h"
#include "mojo/public/cpp/bindings/associated_receiver_set.h"
#include "mojo/public/cpp/bindings/pending_associated_receiver.h"
#include "services/audio/loopback_coordinator.h"

namespace audio {

// Scales the local playout of every output stream in a group, current and
// future, by the last SetVolume() in [0, 1], until the last binding goes away.
// Mirrors LocalMuter: snoopers (loopback and tab capture) still receive the
// unscaled signal, and a muted group stays muted at any volume.
class ArxLocalVolume final : public media::mojom::LocalVolume,
                             public LoopbackGroupObserver::Listener {
 public:
  ArxLocalVolume(LoopbackCoordinator* coordinator,
                 const base::UnguessableToken& group_id);

  ArxLocalVolume(const ArxLocalVolume&) = delete;
  ArxLocalVolume& operator=(const ArxLocalVolume&) = delete;

  ~ArxLocalVolume() final;

  const base::UnguessableToken& group_id() const { return group_id_; }

  // Must be called before the first AddReceiver().
  void SetAllBindingsLostCallback(base::RepeatingClosure callback);
  void AddReceiver(
      mojo::PendingAssociatedReceiver<media::mojom::LocalVolume> receiver);
  bool HasReceivers() const { return !receivers_.empty(); }

  // media::mojom::LocalVolume
  void SetVolume(double volume) final;

  // LoopbackGroupObserver::Listener
  void OnSourceAdded(LoopbackSource* source) final;
  void OnSourceRemoved(LoopbackSource* source) final;

  base::WeakPtr<ArxLocalVolume> GetWeakPtr() {
    return weak_factory_.GetWeakPtr();
  }

 private:
  void OnBindingLost();

  const std::unique_ptr<LoopbackGroupObserver> loopback_group_observer_;
  const base::UnguessableToken group_id_;
  double volume_ = 1.0;

  mojo::AssociatedReceiverSet<media::mojom::LocalVolume> receivers_;
  base::RepeatingClosure all_bindings_lost_callback_;

  SEQUENCE_CHECKER(sequence_checker_);

  base::WeakPtrFactory<ArxLocalVolume> weak_factory_{this};
};

}  // namespace audio

#endif  // SERVICES_AUDIO_ARX_LOCAL_VOLUME_H_
