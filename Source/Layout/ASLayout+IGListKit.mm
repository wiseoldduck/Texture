//
//  ASLayout+IGListKit.mm
//  Texture
//
//  Copyright (c) 2018-present, Pinterest, Inc.  All rights reserved.
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
#import <AsyncDisplayKit/ASAvailability.h>
#if AS_IG_LIST_KIT
#import "ASLayout+IGListKit.h"

@interface ASLayout() {
@public
  id<ASLayoutElement> _layoutElement;
}
@end

@implementation ASLayout(IGListKit)

- (id <NSObject>)diffIdentifier
{
  return [NSValue valueWithPointer: (__bridge void*) self->_layoutElement];
}

- (BOOL)isEqualToDiffableObject:(id <IGListDiffable>)other
{
  if (other == self) return YES;

  ASLayout *otherLayout = ASDynamicCast(other, ASLayout);
  if (!otherLayout) return NO;

  return (otherLayout->_layoutElement == self->_layoutElement);
}
@end
#endif // AS_IG_LIST_KIT
