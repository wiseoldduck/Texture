//
//  ASDisplayNode+Yoga2.h
//  AsyncDisplayKit
//
//  Created by Adlai Holler on 3/8/19.
//  Copyright © 2019 Pinterest. All rights reserved.
//

#import <AsyncDisplayKit/AsyncDisplayKit.h>
#import <UIKit/UIKit.h>

#if YOGA
#import YOGA_CXX_HEADER_PATH
#endif

NS_ASSUME_NONNULL_BEGIN

namespace AS {
namespace Yoga2 {

/**
 * Returns whether Yoga2 is enabled for this node.
 */
bool GetEnabled(ASDisplayNode *node);

inline void AssertEnabled(ASDisplayNode *node) {
  ASDisplayNodeCAssert(GetEnabled(node), @"Expected Yoga2 to be enabled.");
}

inline void AssertDisabled(ASDisplayNode *node) {
  ASDisplayNodeCAssert(!GetEnabled(node), @"Expected Yoga2 to be disabled.");
}

/**
 * Enable Yoga2 for this node. This should be done only once, and before any layout calculations have occurred.
 */
void Enable(ASDisplayNode *node);

/**
 * Asserts unlocked. Locks to root.
 * Marks the node dirty if it has a custom measure function (e.g. text node). Otherwise does
 * nothing.
 */
void MarkContentMeasurementDirty(ASDisplayNode *node);

/**
 * Asserts root. Asserts locked.
 * This is analogous to -sizeThatFits:.
 * Subsequent calls to GetCalculatedSize and GetCalculatedLayout will return values based on this.
 */
void CalculateLayoutAtRoot(ASDisplayNode *node, ASSizeRange constrainedSize);

/**
 * Asserts locked. Asserts thread affinity.
 * Update layout for all nodes in tree from yoga root based on its bounds.
 * This is analogous to -layoutSublayers. If not root, does nothing.
 */
void ApplyLayoutForCurrentBoundsIfRoot(ASDisplayNode *node);

/**
 * Handle a call to -layoutIfNeeded. Asserts thread affinity. Other cases should be handled by
 * pending state.
 *
 * Note: this method _also_ asserts thread affinity for the root yoga node. There are cases where
 * people call -layoutIfNeeded on an unloaded node that has a yoga ancestor that is in hierarchy
 * i.e. the receiver node is pending addition to the layer tree. This is legal only on main.
 */
void HandleExplicitLayoutIfNeeded(ASDisplayNode *node);

/**
 * The size of the most recently calculated layout. Asserts root, locked.
 * Returns CGSizeZero if never measured.
 */
CGSize GetCalculatedSize(ASDisplayNode *node);

/**
 * Returns the most recently calculated layout. Asserts root, locked.
 * Note: The layout will be returned even if the tree is dirty.
 */
ASLayout *_Nullable GetCalculatedLayout(ASDisplayNode *node);

/**
 * Returns a CGRect corresponding to the position and size of the node's children. This is safe to
 * call even during layout or from calculatedLayoutDidChange.
 */
CGRect GetChildrenRect(ASDisplayNode *node);

/// This section for functions only available when yoga is linked.
#if YOGA

/**
 * Get the display node corresponding to the given yoga node.
 */
ASDisplayNode *GetTexture(YGNodeRef yoga);

#endif

}  // namespace Yoga2
}  // namespace AS

NS_ASSUME_NONNULL_END
