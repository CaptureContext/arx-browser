TEST_F(FreezingPolicyInfiniteTabsTest, MediaLeaseBeforeHideWithManyVisibleTabs) {
  // Existing hidden pages leave the MRU allowance as visible tabs fill it.
  for (auto& page : pages_) {
    EXPECT_CALL(*freezer(), MaybeFreezePageNode(page.get()));
  }
  std::vector<TestNodeWrapper<PageNodeImpl>> visible_pages;
  std::vector<TestNodeWrapper<FrameNodeImpl>> visible_frames;
  for (int i = 0;
       i <= features::kInfiniteTabsFreezing_NumProtectedTabs.Get(); ++i) {
    auto page = CreateNode<PageNodeImpl>(
        /*web_contents=*/nullptr, base::UnguessableToken(), GURL(),
        PagePropertyFlags{PagePropertyFlag::kIsVisible});
    page->SetType(PageType::kTab);
    auto frame = CreateFrameNodeAutoId(
        process_node(), page.get(), /*parent_frame_node=*/nullptr,
        content::BrowsingInstanceId(100 + i));
    visible_pages.push_back(std::move(page));
    visible_frames.push_back(std::move(frame));
  }
  VerifyFreezerExpectations();

  auto* source = visible_pages.front().get();
  policy()->AddMediaRunnableLease(source);
  source->SetIsVisible(false);
  EXPECT_FALSE(source->IsVisible());
  EXPECT_FALSE(source->IsAudible());
  ExpectCannotFreezeReasons(source, FreezingType::kInfiniteTabs,
                            ElementsAre(CannotFreezeReason::kMediaRunnableLease));

  // Actual PiP takes over before the pending/candidate scope goes away.
  source->SetHasPictureInPicture(true);
  policy()->RemoveMediaRunnableLease(source);
  ExpectCannotFreezeReasons(source, FreezingType::kInfiniteTabs,
                            ElementsAre(CannotFreezeReason::kPictureInPicture));
  EXPECT_CALL(*freezer(), MaybeFreezePageNode(source));
  source->SetHasPictureInPicture(false);
  VerifyFreezerExpectations();
}
