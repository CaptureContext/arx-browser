// Injected into Chromium's existing FreezingPolicy graph-test translation unit.
// These tests exercise the real policy/freezer bookkeeping, not an embedder mock.
TEST_F(FreezingPolicyTest, MediaLeaseNestedAndAlreadyFrozen) {
  EXPECT_CALL(*freezer(), MaybeFreezePageNode(page_node()));
  policy()->AddFreezeVote(page_node());
  VerifyFreezerExpectations();

  EXPECT_CALL(*freezer(), UnfreezePageNode(page_node()));
  policy()->AddMediaRunnableLease(page_node());
  VerifyFreezerExpectations();
  policy()->AddMediaRunnableLease(page_node());
  policy()->RemoveMediaRunnableLease(page_node());
  ExpectCannotFreezeReasons(page_node(), FreezingType::kVoting,
                            ElementsAre(CannotFreezeReason::kMediaRunnableLease));

  EXPECT_CALL(*freezer(), MaybeFreezePageNode(page_node()));
  policy()->RemoveMediaRunnableLease(page_node());
  VerifyFreezerExpectations();
}

TEST_F(FreezingPolicyTest, ActualPictureInPictureSurvivesLeaseRelease) {
  policy()->AddMediaRunnableLease(page_node());
  policy()->AddFreezeVote(page_node());
  page_node()->SetHasPictureInPicture(true);
  policy()->RemoveMediaRunnableLease(page_node());
  ExpectCannotFreezeReasons(page_node(), FreezingType::kVoting,
                            ElementsAre(CannotFreezeReason::kPictureInPicture));

  EXPECT_CALL(*freezer(), MaybeFreezePageNode(page_node()));
  page_node()->SetHasPictureInPicture(false);
  VerifyFreezerExpectations();
  EXPECT_CALL(*freezer(), UnfreezePageNode(page_node()));
  page_node()->SetHasPictureInPicture(true);
  VerifyFreezerExpectations();
}

TEST_F(FreezingPolicyTest, MediaLeaseRespectsConnectedBrowsingInstances) {
  auto [other, other_frame] =
      CreatePageAndFrameWithBrowsingInstanceId(kBrowsingInstanceA);
  policy()->AddMediaRunnableLease(page_node());
  policy()->AddFreezeVote(page_node());
  policy()->AddFreezeVote(other.get());
  ExpectConnectedCannotFreezeReasons(
      other.get(), FreezingType::kVoting,
      ElementsAre(CannotFreezeReason::kMediaRunnableLease));

  EXPECT_CALL(*freezer(), MaybeFreezePageNode(page_node()));
  EXPECT_CALL(*freezer(), MaybeFreezePageNode(other.get()));
  policy()->RemoveMediaRunnableLease(page_node());
  VerifyFreezerExpectations();
}
