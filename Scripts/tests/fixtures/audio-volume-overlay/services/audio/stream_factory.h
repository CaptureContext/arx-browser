// Upstream excerpts holding the DEV-800 overlay anchors (Chromium 157.0.8103.78).

class LocalMuter;

  void BindMuter(
      mojo::PendingAssociatedReceiver<media::mojom::LocalMuter> receiver,
      const base::UnguessableToken& group_id) final;

  void DestroyMuter(base::WeakPtr<LocalMuter> muter);

  std::vector<std::unique_ptr<LocalMuter>> muters_;
