//
//  ASDisplayNode+Yoga2.mm
//  AsyncDisplayKit
//
//  Created by Adlai Holler on 3/8/19.
//  Copyright © 2019 Pinterest. All rights reserved.
//

#import <AsyncDisplayKit/ASDisplayNode+Yoga2.h>

#if YOGA

#import <AsyncDisplayKit/ASAssert.h>
#import <AsyncDisplayKit/ASCellNode+Internal.h>
#import <AsyncDisplayKit/ASDisplayNode+FrameworkPrivate.h>
#import <AsyncDisplayKit/ASDisplayNode+Yoga2Logging.h>
#import <AsyncDisplayKit/ASDisplayNodeInternal.h>
#import <AsyncDisplayKit/ASInternalHelpers.h>
#import <AsyncDisplayKit/ASLayoutElementStylePrivate.h>
#import <AsyncDisplayKit/NSArray+Diffing.h>
#import <IGListKit/IGListDiff.h>

#import YOGA_CXX_HEADER_PATH
#import YOGA_UTILS_HEADER_PATH

/**
 * A trivial implementation of IGListDiffable for nodes. We currently use IGListDiff to update the
 * node tree to match the yoga tree.
 */
@interface ASDisplayNode (IGListDiffable) <IGListDiffable>
@end
@implementation ASDisplayNode (IGListDiffable)
- (id<NSObject>)diffIdentifier {
  return self;
}
- (BOOL)isEqualToDiffableObject:(id<IGListDiffable>)object {
  return self == object;
}
@end

namespace AS {
namespace Yoga2 {

bool GetEnabled(ASDisplayNode *node) {
  if (node) {
    MutexLocker l(node->__instanceLock__);
    return ASHierarchyStateIncludesYoga2(node->_hierarchyState);
  } else {
    return false;
  }
}

/**
 * Whether to manually round using ASCeilPixelValue instead of Yoga's internal pixel-grid rounding.
 *
 * When it's critical to have exact layout parity between yoga2 and the other layout systems, this
 * flag must be on.
 */
static constexpr bool kUseLegacyRounding = true;

/**
 * Whether to clamp measurement results before returning them into Yoga. This may produce worse
 * visual results, but it matches existing mainline Texture layout. See b/129227140.
 */
static constexpr bool kClampMeasurementResults = true;

static YGConfig *_kSharedConfig;
static dispatch_once_t _kSharedConfigOnce;

static inline YGConfigRef GetSharedConfig() {
  dispatch_once(&_kSharedConfigOnce, ^{
    _kSharedConfig = YGConfigNew();
    _kSharedConfig->logger = Logging::Log;
    _kSharedConfig->pointScaleFactor = ASScreenScale();
  });
  return _kSharedConfig;
}

/// Texture -> Yoga node.
static inline YGNodeRef GetYoga(ASDisplayNode *node) { return [node.style yogaNodeCreateIfNeeded]; }

/// Yoga -> Texture node.
ASDisplayNode *GetTexture(YGNodeRef yoga) { return (__bridge ASDisplayNode *)yoga->getContext(); }

/// Asserts all nodes already locked.
static inline YGNodeRef GetRoot(YGNodeRef yoga) {
  DISABLED_ASAssertLocked(GetTexture(yoga)->__instanceLock__);
  YGNodeRef next = yoga->getOwner();
  while (next) {
    yoga = next;
    DISABLED_ASAssertLocked(GetTexture(yoga)->__instanceLock__);
    next = next->getOwner();
  }
  return yoga;
}

static inline bool IsRoot(YGNodeRef yoga) { return !yoga->getOwner(); }

// Read YGLayout origin, round if legacy, and return as CGPoint.
static inline CGPoint CGOriginOfYogaLayout(const YGLayout &layout) {
  if (kUseLegacyRounding) {
    return CGPointMake(ASCeilPixelValue(layout.position[YGEdgeLeft]),
                       ASCeilPixelValue(layout.position[YGEdgeTop]));
  }
}

// Read YGLayout size, round if legacy, and return as CGSize.
// If layout has undefined values, returns CGSizeZero.
static inline CGSize CGSizeOfYogaLayout(const YGLayout &layout) {
  if (YGFloatArrayEqual(layout.dimensions, kYGDefaultDimensionValues)) {
    return CGSizeZero;
  }

  if (kUseLegacyRounding) {
    return CGSizeMake(ASCeilPixelValue(layout.dimensions[YGDimensionWidth]),
                      ASCeilPixelValue(layout.dimensions[YGDimensionHeight]));
  }
}

static inline CGRect CGRectOfYogaLayout(const YGLayout &layout) {
  return {CGOriginOfYogaLayout(layout), CGSizeOfYogaLayout(layout)};
}

static inline void AssertRoot(ASDisplayNode *node) {
  ASDisplayNodeCAssert(IsRoot(GetYoga(node)), @"Must be called on root: %@", node);
}

/**
 * We are root and the tree is dirty. There are few things we need to do.
 * **All of the following must be done on the main thread, so the first thing is to get there.**
 * - If we are loaded, we need to call [layer setNeedsLayout] on main.
 * - If we are range-managed, we need to inform our container that our size is invalid.
 * - If we are in hierarchy, we need to call [superlayer setNeedsLayout] so that it knows that we
 * (may) need resizing.
 */
void HandleRootDirty(ASDisplayNode *node) {
  MutexLocker l(node->__instanceLock__);
  unowned CALayer *layer = node->_layer;
  const bool isRangeManaged = ASHierarchyStateIncludesRangeManaged(node->_hierarchyState);

  // Not loaded, not range managed, nothing to be done.
  if (!layer && !isRangeManaged) {
    return;
  }

  // Not on main thread. Get on the main thread and come back in.
  if (!ASDisplayNodeThreadIsMain()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      HandleRootDirty(node);
    });
    return;
  }

  // On main. If no longer root, nothing to be done. Our new tree was invalidated when we got
  // added to it.
  YGNodeRef yoga = GetYoga(node);
  if (!IsRoot(yoga)) {
    return;
  }

  // Loaded or range-managed. On main. Root. Locked.

  // Dirty our own layout so that even if our size didn't change we get a layout pass.
  [layer setNeedsLayout];

  // If we are a cell node with an interaction delegate, inform it our size is invalid.
  if (id<ASCellNodeInteractionDelegate> interactionDelegate =
          ASDynamicCast(node, ASCellNode).interactionDelegate) {
    [interactionDelegate nodeDidInvalidateSize:(ASCellNode *)node];
  } else {
    // Otherwise just inform our superlayer (if we have one.)
    [layer.superlayer setNeedsLayout];
  }
}

void YogaDirtied(YGNodeRef yoga) {
  // NOTE: We may be locked – if someone set a property directly on us – or we may not – if this
  // dirtiness is propagating up from below.

  // If we are not root, ignore. Yoga will propagate the dirt up to root.
  if (IsRoot(yoga)) {
    HandleRootDirty(GetTexture(yoga));
  }
}

/// If mode is undefined, returns CGFLOAT_MAX. Otherwise asserts valid & converts to CGFloat.
CGFloat CGConstraintFromYoga(float dim, YGMeasureMode mode) {
  if (mode == YGMeasureModeUndefined) {
    return CGFLOAT_MAX;
  } else {
    ASDisplayNodeCAssert(dim != YGUndefined, @"Yoga said it gave us a size but it didn't.");
    return dim;
  }
}

inline float YogaConstraintFromCG(CGFloat constraint) {
  return constraint == CGFLOAT_MAX || isinf(constraint) ? YGUndefined : constraint;
}

/// Convert a Yoga layout to an ASLayout.
ASLayout *ASLayoutCreateFromYogaNodeLayout(YGNodeRef yoga, CGSize minSize) {
  // If our layout has no dimensions, return nil now.
  const YGLayout &layout = yoga->getLayout();
  if (YGFloatArrayEqual(layout.dimensions, kYGDefaultDimensionValues)) {
    return nil;
  }

  const YGVector &children = yoga->getChildren();
  ASLayout *sublayouts[children.size()];
  int i = 0;
  for (const YGNodeRef &child : children) {
    // If any node in the subtree has no layout, then there is no layout. Return nil.
    if (!(sublayouts[i] = ASLayoutCreateFromYogaNodeLayout(child, CGSizeZero))) {
      return nil;
    }
    i++;
  }
  auto boxed_sublayouts = [NSArray<ASLayout *> arrayByTransferring:sublayouts
                                                             count:children.size()];
  CGSize yogaLayoutSize = CGSizeOfYogaLayout(layout);
  CGSize size = CGSizeMake(max(yogaLayoutSize.width, minSize.width),
                           max(yogaLayoutSize.height, minSize.height));
  return [[ASLayout alloc] initWithLayoutElement:GetTexture(yoga)
                                            size:size
                                        position:CGOriginOfYogaLayout(layout)
                                      sublayouts:boxed_sublayouts];
}

// Only set on nodes that implement calculateSizeThatFits:.
YGSize YogaMeasure(YGNodeRef yoga, float width, YGMeasureMode widthMode, float height,
                   YGMeasureMode heightMode) {
  ASDisplayNode *node = GetTexture(yoga);

  // Go straight to calculateSizeThatFits:, not sizeThatFits:. Caching is handled inside of yoga –
  // if we got here, we need to do a calculation so call out to the node subclass.
  const CGSize constraint =
      CGSizeMake(CGConstraintFromYoga(width, widthMode), CGConstraintFromYoga(height, heightMode));
  CGSize size = [node calculateSizeThatFits:constraint];

  if (kClampMeasurementResults) {
    size.width = MIN(size.width, constraint.width);
    size.height = MIN(size.height, constraint.height);
  }

  // To match yoga1, we ceil this value (see ASLayoutElementYogaMeasureFunc).
  if (kUseLegacyRounding) {
    size = ASCeilSizeValues(size);
  }

  // Do verbose logging if enabled.
#if ASEnableVerboseLogging
  NSString *thread = @"";
  if (ASDisplayNodeThreadIsMain()) {
    // good place for a breakpoint.
    thread = @"main thread ";
  }
  as_log_verbose(ASLayoutLog(), "did %@leaf measurement for %@ (%g %g) -> (%g %g)", thread,
                 ASObjectDescriptionMakeTiny(node), constraint.width, constraint.height, size.width,
                 size.height);
#endif  // ASEnableVerboseLogging

  return {(float)size.width, (float)size.height};
}

// Set on every node. This was carried from original integration. Wonder if we can be smarter.
float YogaBaseline(YGNodeRef yoga, float width, float height) {
  unowned ASDisplayNode *node = GetTexture(yoga);
  if (!node) {
    ASDisplayNodeCFailAssert(@"Texture node not associated.");
    return 0;
  }

  MutexLocker l(node->__instanceLock__);
  unowned ASLayoutElementStyle *style = node.style;

  switch (node->_supernode->_style.alignItems) {
    case ASStackLayoutAlignItemsBaselineFirst:
      return style.ascender;
    case ASStackLayoutAlignItemsBaselineLast:
      return height + style.descender;
    default:
      return 0;
  }
}

void Enable(ASDisplayNode *texture) {
  NSCParameterAssert(texture != nil);
  if (!texture) {
    return;
  }
  MutexLocker l(texture->__instanceLock__);
  YGNodeRef yoga = texture.style.yogaNodeCreateIfNeeded;
  yoga->setConfig(GetSharedConfig());
  yoga->setContext((__bridge void *)texture);
  yoga->setDirtiedFunc(&YogaDirtied);
  yoga->setBaseLineFunc(&YogaBaseline);
  // Note: No print func. See Yoga2Logging.h.

  // Set measure func if needed.
  if (0 != (texture->_methodOverrides & ASDisplayNodeMethodOverrideCalcSizeThatFits)) {
    yoga->setMeasureFunc(&YogaMeasure);
  }
}

void MarkContentMeasurementDirty(ASDisplayNode *node) {
  DISABLED_ASAssertUnlocked(node);
  AS::LockSet locks = [node lockToRootIfNeededForLayout];
  AssertEnabled(node);
  YGNodeRef yoga = GetYoga(node);
  if (yoga->getMeasure() && !yoga->isDirty()) {
    as_log_verbose(ASLayoutLog(), "mark content dirty for %@", ASObjectDescriptionMakeTiny(node));
    yoga->markDirtyAndPropogate();  // NOTYPO The yoga authors misspelled that function name.
  }
}

void CalculateLayoutAtRoot(ASDisplayNode *node, ASSizeRange sizeRange) {
  AssertEnabled(node);
  DISABLED_ASAssertLocked(node->__instanceLock__);
  AssertRoot(node);

  // Notify.
  [node willCalculateLayout:sizeRange];
  [node enumerateInterfaceStateDelegates:^(id<ASInterfaceStateDelegate> _Nonnull delegate) {
    if ([delegate respondsToSelector:@selector(nodeWillCalculateLayout:)]) {
      [delegate nodeWillCalculateLayout:sizeRange];
    }
  }];

  // Log the calculation request.
#if ASEnableVerboseLogging
  static std::atomic<long> counter(1);
  const long request_id = counter.fetch_add(1);
  as_log_verbose(ASLayoutLog(), "enter layout calculation %ld for %@: %@", request_id,
                 ASObjectDescriptionMakeTiny(node), NSStringFromCGSize(maxSize));
#endif

  const YGNodeRef yoga = GetYoga(node);

  // Force setting flex shrink to 0 on all children of nodes with YGOverflowScroll. This preserves
  // backwards compatibility with Yoga1, but we should consider a breaking change going forward to
  // remove this, as it's not great to meddle with flex properties arbitrarily.
  // TODO(b/134073740): [Yoga2 Launch] Re-consider this.
  YGTraversePreOrder(yoga, [](YGNodeRef yoga) {
    if (yoga->getStyle().overflow == YGOverflowScroll) {
      for (const auto &yoga_child : yoga->getChildren()) {
        yoga_child->getStyle().flexShrink = YGFloatOptional(0);
      }
    }
  });

  // Do the calculation.
  YGNodeCalculateLayout(yoga, YogaConstraintFromCG(sizeRange.max.width),
                        YogaConstraintFromCG(sizeRange.max.height), YGDirectionInherit);
  node->_yogaCalculatedLayoutSizeRange = sizeRange;

  // Log and return result.
#if ASEnableVerboseLogging
  const CGSize result = CGSizeOfYogaLayout(yoga->getLayout());
  as_log_verbose(ASLayoutLog(), "finish layout calculation %ld with %@", request_id,
                 NSStringFromCGSize(result));
#endif
}

void ApplyLayoutForCurrentBoundsIfRoot(ASDisplayNode *node) {
  AssertEnabled(node);
  ASDisplayNodeCAssertThreadAffinity(node);
  DISABLED_ASAssertLocked(node->__instanceLock__);
  YGNodeRef yoga_root = GetYoga(node);

  // We always update the entire tree from root and push all invalidations to the top. Nodes that do
  // not have a different layout will be ignored using their `yoga->getHasNewLayout()` flag.
  if (!IsRoot(yoga_root)) {
    return;
  }

  // Note: We used to short-circuit here when the Yoga root had no children. However, we need to
  // ensure that calculatedLayoutDidChange is called, so we need to pass through. The Yoga
  // calculation should be cached, so it should be a cheap operation.

#if ASEnableVerboseLogging
  static std::atomic<long> counter(1);
  const long layout_id = counter.fetch_add(1);
  as_log_verbose(ASLayoutLog(), "enter layout apply %ld for %@", layout_id,
                 ASObjectDescriptionMakeTiny(node));
#endif

  // Determine a compatible size range to measure with. Yoga can create slightly different layouts
  // if we re-measure with a different constraint than previously (even if it matches the resulting
  // size of the previous measurement, due to rounding errors!), so avoid remeasuring if the
  // caller is clearly just trying to apply the previous measurement.
  ASSizeRange sizeRange = ASSizeRangeMake(node.bounds.size);
  if (CGSizeEqualToSize(node.bounds.size, GetCalculatedSize(node))) {
    sizeRange = node->_yogaCalculatedLayoutSizeRange;
  }

  // Calculate layout for our bounds. If this size is compatible with a previous calculation
  // then the measurement cache will kick in.
  CalculateLayoutAtRoot(node, sizeRange);

  const bool tree_loaded = _loaded(node);
  // Traverse down the yoga tree, cleaning each node.
  YGTraversePreOrder(yoga_root, [&yoga_root, tree_loaded](YGNodeRef yoga) {
    // If the layout hasn't changed, skip it.
    if (!yoga->getHasNewLayout()) {
      if (yoga->getStyle().overflow == YGOverflowScroll) {
        // If a node has YGOverflowScroll, then always call calculatedLayoutDidChange so it can
        // respond to any changes in the layout of its children.
        unowned ASDisplayNode *node = GetTexture(yoga);
        [node calculatedLayoutDidChange];
      }
      return;
    }
    yoga->setHasNewLayout(false);

    unowned ASDisplayNode *node = GetTexture(yoga);
    if (DISPATCH_EXPECT(node == nil, 0)) {
      ASDisplayNodeCFailAssert(@"No texture node.");
      return;
    }

    // Lock this node. Note we are already locked at root so if we ever get to the point where trees
    // share one lock, this line can go away.
    MutexLocker l(node->__instanceLock__);

    // Set node frame unless we ARE root. Root already has its frame.
    if (yoga != yoga_root) {
      const CGRect newFrame = CGRectOfYogaLayout(yoga->getLayout());
      as_log_verbose(ASLayoutLog(), "layout: %@ %@ -> %@", ASObjectDescriptionMakeTiny(node),
                     NSStringFromCGRect(node.frame), NSStringFromCGRect(newFrame));
      node.frame = newFrame;
    }

    // Update the node tree to match the yoga tree.
    if (!ASObjectIsEqual(node->_subnodes, node->_yogaChildren)) {
      // Calculate the diff.
      IGListIndexSetResult *diff =
          IGListDiff(node->_subnodes, node->_yogaChildren, IGListDiffEquality);

      // Log the diff.
      as_log_verbose(ASLayoutLog(), "layout: %@ updating children",
                     ASObjectDescriptionMakeTiny(node));

      // Apply the diff.

      // If we have moves, we need to apply them at the end but use the original indexes for
      // move-from. It would be great to do this in-place but correctness comes first. See
      // discussion at https://github.com/Instagram/IGListKit/issues/1006 We use unowned here
      // because ownership is established by the _real_ subnodes array, and this is quite a
      // performance-sensitive code path. Note also, we could opt to create a vector of ONLY the
      // moved subnodes, but I bet this approach is faster since it's just a memcpy rather than
      // repeated objectAtIndex: calls with all their retain/release traffic.
      std::vector<unowned ASDisplayNode *> oldSubnodesForMove;
      if (diff.moves.count) {
        oldSubnodesForMove.reserve(node->_subnodes.count);
        [node->_subnodes getObjects:oldSubnodesForMove.data()];
      }

      // Deletes descending so we don't invalidate our own indexes.
      NSIndexSet *deletes = diff.deletes;
      for (NSInteger i = deletes.lastIndex; i != NSNotFound; i = [deletes indexLessThanIndex:i]) {
        as_log_verbose(ASLayoutLog(), "removing %@",
                       ASObjectDescriptionMakeTiny(node->_subnodes[i]));
        // If tree isn't loaded, we never do deferred removal. Remove now.
        if (!tree_loaded) {
          [node->_subnodes[i] removeFromSupernode];
          continue;
        }

        // If it is loaded, ask if any node in the subtree wants to defer.
        // Unfortunately unconditionally deferring causes unexpected behavior for e.g. unit tests
        // that depend on the tree reflecting its new state immediately by default.
        [CATransaction begin];
        __block BOOL shouldDefer = NO;
        ASDisplayNodePerformBlockOnEveryNode(
            nil, node->_subnodes[i], NO, ^(ASDisplayNode *blockNode) {
              shouldDefer |= [blockNode _shouldDeferAutomaticRemoval];
            });
        if (shouldDefer) {
          ASDisplayNode *subnode = node->_subnodes[i];
          [CATransaction setCompletionBlock:^{
            [subnode removeFromSupernode];
          }];
        } else {
          [node->_subnodes[i] removeFromSupernode];
        }
        [CATransaction commit];
      }

      // Inserts.
      NSIndexSet *inserts = diff.inserts;
      for (NSInteger i = inserts.firstIndex; i != NSNotFound;
           i = [inserts indexGreaterThanIndex:i]) {
        as_log_verbose(ASLayoutLog(), "inserting %@ at %ld",
                       ASObjectDescriptionMakeTiny(node->_yogaChildren[i]), (long)i);
        [node insertSubnode:node->_yogaChildren[i] atIndex:i];
      }

      // Moves. Manipulate the arrays directly to avoid extra traffic.
      // Like all other subnode mutations, this invalidates cached subnodes.
      if (diff.moves.count > 0) {
        node->_cachedSubnodes = nil;
      }
      for (IGListMoveIndex *idx in diff.moves) {
        auto &subnode = oldSubnodesForMove[idx.from];
        as_log_verbose(ASLayoutLog(), "moving %@ to %ld", ASObjectDescriptionMakeTiny(subnode),
                       (long)idx.to);
        MutexLocker l(subnode->__instanceLock__);
        [node->_subnodes removeObjectIdenticalTo:subnode];
        [node->_subnodes insertObject:subnode atIndex:idx.to];
        // If tree is loaded and subnode isn't rasterized, update view or layer array.
        if (tree_loaded && !ASHierarchyStateIncludesRasterized(subnode->_hierarchyState)) {
          if (subnode->_flags.layerBacked) {
            [node->_layer insertSublayer:subnode->_layer atIndex:(unsigned int)idx.to];
          } else {
            [node->_view insertSubview:subnode->_view atIndex:idx.to];
          }
        }
      }

      // Invalidate accessibility if needed due to tree change.
      [node invalidateAccessibleElementsIfNeeded];
    }

    // Notify calculated layout changed (calculated here really means "applied" – misnomer.)
    [node calculatedLayoutDidChange];
  });
}

void HandleExplicitLayoutIfNeeded(ASDisplayNode *node) {
  ASDisplayNodeCAssertThreadAffinity(node);
  if (_loaded(node)) {
    // We are loaded. Just call this on the layer. It will escalate to the highest dirty layer and
    // update downward. Since we're on main, we can access the layer without lock.
    [node->_layer layoutIfNeeded];
    return;
  }

  // We are not loaded. Our yoga root actually might be loaded and in hierarchy though!
  // Lock to root, and repeat the call on the yoga root.
  AS::LockSet locks = [node lockToRootIfNeededForLayout];
  YGNodeRef yoga_self = GetYoga(node);
  YGNodeRef yoga_root = GetRoot(yoga_self);
  // Unfortunately we have to unlock here, or else we trigger an assertion when we call out to the
  // subclasses during layout.
  locks.clear();
  if (yoga_self != yoga_root) {
    // Go back through the layoutIfNeeded code path in case the root node is loaded when we aren't.
    ASDisplayNode *rootNode = GetTexture(yoga_root);
    [rootNode layoutIfNeeded];
  } else {
    // OK we are: yoga root, not loaded.
    // That means all we need to do is call __layout and we will apply layout based on current
    // bounds.
    [node __layout];
  }
}

CGSize GetCalculatedSize(ASDisplayNode *node) {
  AssertEnabled(node);
  DISABLED_ASAssertLocked(GetTexture(GetRoot(GetYoga(node)))->__instanceLock__);

  CGSize size = CGSizeOfYogaLayout(GetYoga(node)->getLayout());
  return CGSizeMake(max(size.width, node->_yogaCalculatedLayoutSizeRange.min.width),
                    max(size.height, node->_yogaCalculatedLayoutSizeRange.min.height));
}

ASLayout *GetCalculatedLayout(ASDisplayNode *node) {
  AssertEnabled(node);
  DISABLED_ASAssertLocked(GetTexture(GetRoot(GetYoga(node)))->__instanceLock__);

  return ASLayoutCreateFromYogaNodeLayout(GetYoga(node), node->_yogaCalculatedLayoutSizeRange.min);
}

CGRect GetChildrenRect(ASDisplayNode *node) {
  AssertEnabled(node);
  DISABLED_ASAssertLocked(GetTexture(GetRoot(GetYoga(node)))->__instanceLock__);

  CGRect childrenRect = CGRectZero;
  YGNodeRef yoga_self = GetYoga(node);
  for (const auto &yoga_child : yoga_self->getChildren()) {
    CGRect frame = CGRectOfYogaLayout(yoga_child->getLayout());
    childrenRect = CGRectUnion(childrenRect, frame);
  }

  return childrenRect;
}

#else  // !YOGA

bool GetEnabled(ASDisplayNode *node) { return false; }
void AlertNeedYoga() {
  ASDisplayNodeCFailAssert(@"Yoga experiment is enabled but we were compiled without yoga!");
}
void Enable(ASDisplayNode *node) {
  AssertEnabled();
  AlertNeedYoga();
}
void MarkContentMeasurementDirty(ASDisplayNode *node) {
  AssertEnabled();
  AlertNeedYoga();
}
CGSize SizeThatFits(ASDisplayNode *node, CGSize maxSize) {
  AssertEnabled();
  AlertNeedYoga();
  return CGSizeZero;
}
void ApplyLayoutForCurrentBoundsIfRoot(ASDisplayNode *node) {
  AssertEnabled();
  AlertNeedYoga();
}
CGSize GetCalculatedSize(ASDisplayNode *node) {
  AssertEnabled();
  AlertNeedYoga();
  return CGSizeZero;
}
ASLayout *GetCalculatedLayout(ASDisplayNode *node) {
  AssertEnabled();
  AlertNeedYoga();
  return nil;
}
CGRect GetChildrenRect(ASDisplayNode *node) {
  AssertEnabled();
  AlertNeedYoga();
  return CGRectZero;
}

#endif  // YOGA

}  // namespace Yoga2
}  // namespace AS
