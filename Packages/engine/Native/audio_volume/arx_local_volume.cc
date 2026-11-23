// Arx (DEV-800). Copied to services/audio by Scripts/engine/audio_volume_overlay.py.

#include "services/audio/arx_local_volume.h"

#include <cmath>
#include <utility>

#include "base/functional/bind.h"

namespace audio {

namespace {

void ApplyGroupVolume(double volume, LoopbackSource* source) {
  source->SetGroupVolume(volume);
}

}  // namespace

ArxLocalVolume::ArxLocalVolume(LoopbackCoordinator* coordinator,
                               const base::UnguessableToken& group_id)
    : loopback_group_observer_(
          LoopbackGroupObserver::CreateMatchingGroupObserver(coordinator,
                                                             group_id)),
      group_id_(group_id) {
  loopback_group_observer_->StartObserving(this);
  receivers_.set_disconnect_handler(base::BindRepeating(
      &ArxLocalVolume::OnBindingLost, base::Unretained(this)));
}

ArxLocalVolume::~ArxLocalVolume() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  // Back to full volume for the streams that outlive this group's binding.
  loopback_group_observer_->ForEachSource(
      base::BindRepeating(&ApplyGroupVolume, 1.0));
  loopback_group_observer_->StopObserving();
}

void ArxLocalVolume::SetAllBindingsLostCallback(
    base::RepeatingClosure callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  all_bindings_lost_callback_ = std::move(callback);
}

void ArxLocalVolume::AddReceiver(
    mojo::PendingAssociatedReceiver<media::mojom::LocalVolume> receiver) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  receivers_.Add(this, std::move(receiver));
}

void ArxLocalVolume::SetVolume(double volume) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!std::isfinite(volume) || volume < 0 || volume > 1) {
    receivers_.ReportBadMessage("Invalid group volume");
    return;
  }
  volume_ = volume;
  loopback_group_observer_->ForEachSource(
      base::BindRepeating(&ApplyGroupVolume, volume_));
}

void ArxLocalVolume::OnSourceAdded(LoopbackSource* source) {
  // A stream joining the group starts at the group's volume.
  source->SetGroupVolume(volume_);
}

void ArxLocalVolume::OnSourceRemoved(LoopbackSource* source) {
  // As LocalMuter: a source leaves the group as its stream is destroyed.
}

void ArxLocalVolume::OnBindingLost() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!HasReceivers() && all_bindings_lost_callback_) {
    all_bindings_lost_callback_.Run();
  }
}

}  // namespace audio
