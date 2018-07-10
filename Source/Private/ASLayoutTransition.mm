//
//  ASLayoutTransition.mm
//  Texture
//
//  Copyright (c) 2014-present, Facebook, Inc.  All rights reserved.
//  This source code is licensed under the BSD-style license found in the
//  LICENSE file in the /ASDK-Licenses directory of this source tree. An additional
//  grant of patent rights can be found in the PATENTS file in the same directory.
//
//  Modifications to this file made after 4/13/2017 are: Copyright (c) 2017-present,
//  Pinterest, Inc.  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//

#import <AsyncDisplayKit/ASLayoutTransition.h>

#import <AsyncDisplayKit/ASDisplayNode+Beta.h>
#import <AsyncDisplayKit/NSArray+Diffing.h>

#import <AsyncDisplayKit/ASLayout.h>
#import <AsyncDisplayKit/ASDisplayNodeInternal.h> // Required for _insertSubnode... / _removeFromSupernode.
#import <AsyncDisplayKit/ASLog.h>

#import <queue>

#if AS_IG_LIST_KIT
#import <IGListKit/IGListKit.h>
#import <AsyncDisplayKit/ASLayout+IGListKit.h>
#endif

/**
 * Search the whole layout stack if at least one layout has a layoutElement object that can not be layed out asynchronous.
 * This can be the case for example if a node was already loaded
 */
static inline BOOL ASLayoutCanTransitionAsynchronous(ASLayout *layout) {
  // Queue used to keep track of sublayouts while traversing this layout in a BFS fashion.
  std::queue<ASLayout *> queue;
  queue.push(layout);
  
  while (!queue.empty()) {
    layout = queue.front();
    queue.pop();
    
#if DEBUG
    ASDisplayNodeCAssert([layout.layoutElement conformsToProtocol:@protocol(ASLayoutElementTransition)], @"ASLayoutElement in a layout transition needs to conforms to the ASLayoutElementTransition protocol.");
#endif
    if (((id<ASLayoutElementTransition>)layout.layoutElement).canLayoutAsynchronous == NO) {
      return NO;
    }
    
    // Add all sublayouts to process in next step
    for (ASLayout *sublayout in layout.sublayouts) {
      queue.push(sublayout);
    }
  }
  
  return YES;
}

@implementation ASLayoutTransition {
  std::shared_ptr<ASDN::RecursiveMutex> __instanceLock__;
  
  BOOL _calculatedSubnodeOperations;
  NSArray<ASDisplayNode *> *_insertedSubnodes;
  NSArray<ASDisplayNode *> *_removedSubnodes;
  std::vector<NSUInteger> _insertedSubnodePositions;
  std::vector<std::pair<ASDisplayNode *, NSUInteger>> _subnodeMoves;
}

- (instancetype)initWithNode:(ASDisplayNode *)node
               pendingLayout:(std::shared_ptr<ASDisplayNodeLayout>)pendingLayout
              previousLayout:(std::shared_ptr<ASDisplayNodeLayout>)previousLayout
{
  self = [super init];
  if (self) {
    __instanceLock__ = std::make_shared<ASDN::RecursiveMutex>();
      
    _node = node;
    _pendingLayout = pendingLayout;
    _previousLayout = previousLayout;
  }
  return self;
}

- (BOOL)isSynchronous
{
  ASDN::MutexSharedLocker l(__instanceLock__);
  return !ASLayoutCanTransitionAsynchronous(_pendingLayout->layout);
}

- (void)commitTransition
{
  [self applySubnodeRemovals];
  [self applySubnodeInsertionsAndMoves];
}

- (void)applySubnodeInsertionsAndMoves
{
  ASDN::MutexSharedLocker l(__instanceLock__);
  [self calculateSubnodeOperationsIfNeeded];
  
  // Create an activity even if no subnodes affected.
  as_activity_create_for_scope("Apply subnode insertions and moves");
  if (_insertedSubnodePositions.size() == 0 && _subnodeMoves.size() == 0) {
    return;
  }

  ASDisplayNodeLogEvent(_node, @"insertSubnodes: %@", _insertedSubnodes);
  NSUInteger i = 0;
  NSUInteger j = 0;
  for (auto const &move : _subnodeMoves) {
    [move.first _removeFromSupernodeIfEqualTo:_node];
  }
  j = 0;
  while (i < _insertedSubnodePositions.size() && j < _subnodeMoves.size()) {
    NSUInteger p = _insertedSubnodePositions[i];
    NSUInteger q = _subnodeMoves[j].second;
    if (p < q) {
      [_node _insertSubnode:_insertedSubnodes[i] atIndex:p];
      i++;
    } else {
      [_node _insertSubnode:_subnodeMoves[j].first atIndex:q];
      j++;
    }
  }
  for (; i < _insertedSubnodePositions.size(); ++i) {
    [_node _insertSubnode:_insertedSubnodes[i] atIndex:_insertedSubnodePositions[i]];
  }
  for (; j < _subnodeMoves.size(); ++j) {
    [_node _insertSubnode:_subnodeMoves[j].first atIndex:_subnodeMoves[j].second];
  }
}

- (void)applySubnodeRemovals
{
  as_activity_scope(as_activity_create("Apply subnode removals", AS_ACTIVITY_CURRENT, OS_ACTIVITY_FLAG_DEFAULT));
  ASDN::MutexSharedLocker l(__instanceLock__);
  [self calculateSubnodeOperationsIfNeeded];

  if (_removedSubnodes.count == 0) {
    return;
  }

  ASDisplayNodeLogEvent(_node, @"removeSubnodes: %@", _removedSubnodes);
  for (ASDisplayNode *subnode in _removedSubnodes) {
    // In this case we should only remove the subnode if it's still a subnode of the _node that executes a layout transition.
    // It can happen that a node already did a layout transition and added this subnode, in this case the subnode
    // would be removed from the new node instead of _node
    if (_node.automaticallyManagesSubnodes) {
      [subnode _removeFromSupernodeIfEqualTo:_node];
    }
  }
}

- (void)calculateSubnodeOperationsIfNeeded
{
  ASDN::MutexSharedLocker l(__instanceLock__);
  if (_calculatedSubnodeOperations) {
    return;
  }
  
  // Create an activity even if no subnodes affected.
  as_activity_create_for_scope("Calculate subnode operations");
  ASLayout *previousLayout = _previousLayout->layout;
  ASLayout *pendingLayout = _pendingLayout->layout;

  if (previousLayout) {
#if AS_IG_LIST_KIT
    // IGListDiff completes in linear time O(m+n), so use it if we have it:
    IGListIndexSetResult *result = IGListDiff(previousLayout.sublayouts, pendingLayout.sublayouts, IGListDiffEquality);
    _insertedSubnodePositions = findNodesInLayoutAtIndexes(pendingLayout, result.inserts, &_insertedSubnodes);
    findNodesInLayoutAtIndexes(previousLayout, result.deletes, &_removedSubnodes);
    for (IGListMoveIndex *move in result.moves) {
      _subnodeMoves.push_back(std::make_pair(previousLayout.sublayouts[move.from].layoutElement, move.to));
    }

    // Sort by ascending order of move destinations, this will allow easy loop of `insertSubnode:AtIndex` later.
    std::sort(_subnodeMoves.begin(), _subnodeMoves.end(), [](std::pair<id<ASLayoutElement>, NSUInteger> a,
            std::pair<ASDisplayNode *, NSUInteger> b) {
      return a.second < b.second;
    });
#else
    NSIndexSet *insertions, *deletions;
    NSArray<NSIndexPath *> *moves;
    NSArray<ASDisplayNode *> *previousNodes = [previousLayout.sublayouts valueForKey:@"layoutElement"];
    NSArray<ASDisplayNode *> *pendingNodes = [pendingLayout.sublayouts valueForKey:@"layoutElement"];
    [previousNodes asdk_diffWithArray:pendingNodes
                                       insertions:&insertions
                                        deletions:&deletions
                                            moves:&moves];

    _insertedSubnodePositions = findNodesInLayoutAtIndexes(pendingLayout, insertions, &_insertedSubnodes);
    _removedSubnodes = [previousNodes objectsAtIndexes:deletions];
    // These should arrive sorted in ascending order of move destinations.
    for (NSIndexPath *move in moves) {
      _subnodeMoves.push_back(std::make_pair(previousLayout.sublayouts[([move indexAtPosition:0])].layoutElement,
              [move indexAtPosition:1]));
    }
#endif
  } else {
    NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [pendingLayout.sublayouts count])];
    _insertedSubnodePositions = findNodesInLayoutAtIndexes(pendingLayout, indexes, &_insertedSubnodes);
    _removedSubnodes = nil;
  }
  _calculatedSubnodeOperations = YES;
}

#pragma mark - _ASTransitionContextDelegate

- (NSArray<ASDisplayNode *> *)currentSubnodesWithTransitionContext:(_ASTransitionContext *)context
{
  ASDN::MutexSharedLocker l(__instanceLock__);
  return _node.subnodes;
}

- (NSArray<ASDisplayNode *> *)insertedSubnodesWithTransitionContext:(_ASTransitionContext *)context
{
  ASDN::MutexSharedLocker l(__instanceLock__);
  [self calculateSubnodeOperationsIfNeeded];
  return _insertedSubnodes;
}

- (NSArray<ASDisplayNode *> *)removedSubnodesWithTransitionContext:(_ASTransitionContext *)context
{
  ASDN::MutexSharedLocker l(__instanceLock__);
  [self calculateSubnodeOperationsIfNeeded];
  return _removedSubnodes;
}

- (ASLayout *)transitionContext:(_ASTransitionContext *)context layoutForKey:(NSString *)key
{
  ASDN::MutexSharedLocker l(__instanceLock__);
  if ([key isEqualToString:ASTransitionContextFromLayoutKey]) {
    return _previousLayout->layout;
  } else if ([key isEqualToString:ASTransitionContextToLayoutKey]) {
    return _pendingLayout->layout;
  } else {
    return nil;
  }
}

- (ASSizeRange)transitionContext:(_ASTransitionContext *)context constrainedSizeForKey:(NSString *)key
{
  ASDN::MutexSharedLocker l(__instanceLock__);
  if ([key isEqualToString:ASTransitionContextFromLayoutKey]) {
    return _previousLayout->constrainedSize;
  } else if ([key isEqualToString:ASTransitionContextToLayoutKey]) {
    return _pendingLayout->constrainedSize;
  } else {
    return ASSizeRangeMake(CGSizeZero, CGSizeZero);
  }
}

#pragma mark - Filter helpers

/**
 * @abstract Stores the nodes at the given indexes in the `storedNodes` array, storing indexes in a `storedPositions` c++ vector.
 */
static inline std::vector<NSUInteger> findNodesInLayoutAtIndexes(ASLayout *layout,
                                                                 NSIndexSet *indexes,
                                                                 NSArray<ASDisplayNode *> * __strong *storedNodes)
{
  return findNodesInLayoutAtIndexesWithFilteredNodes(layout, indexes, nil, storedNodes);
}

/**
 * @abstract Stores the nodes at the given indexes in the `storedNodes` array, storing indexes in a `storedPositions` c++ vector.
 * @discussion If the node exists in the `filteredNodes` array, the node is not added to `storedNodes`.
 */
static inline std::vector<NSUInteger> findNodesInLayoutAtIndexesWithFilteredNodes(ASLayout *layout,
                                                                                  NSIndexSet *indexes,
                                                                                  NSArray<ASDisplayNode *> *filteredNodes,
                                                                                  NSArray<ASDisplayNode *> * __strong *storedNodes)
{
  NSMutableArray<ASDisplayNode *> *nodes = [NSMutableArray arrayWithCapacity:indexes.count];
  std::vector<NSUInteger> positions = std::vector<NSUInteger>();
  
  // From inspection, this is how enumerateObjectsAtIndexes: works under the hood
  NSUInteger firstIndex = indexes.firstIndex;
  NSUInteger lastIndex = indexes.lastIndex;
  NSUInteger idx = 0;
  for (ASLayout *sublayout in layout.sublayouts) {
    if (idx > lastIndex) { break; }
    if (idx >= firstIndex && [indexes containsIndex:idx]) {
      ASDisplayNode *node = ASDynamicCast(sublayout.layoutElement, ASDisplayNode);
      ASDisplayNodeCAssert(node, @"ASDisplayNode was deallocated before it was added to a subnode. It's likely the case that you use automatically manages subnodes and allocate a ASDisplayNode in layoutSpecThatFits: and don't have any strong reference to it.");
      // Ignore the odd case in which a non-node sublayout is accessed and the type cast fails
      if (node != nil) {
        BOOL notFiltered = (filteredNodes == nil || [filteredNodes indexOfObjectIdenticalTo:node] == NSNotFound);
        if (notFiltered) {
          [nodes addObject:node];
          positions.push_back(idx);
        }
      }
    }
    idx += 1;
  }
  *storedNodes = nodes;
  
  return positions;
}

@end
