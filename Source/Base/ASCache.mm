//
//  ASCache.mm
//  Texture
//
//  Copyright (c) 2018-present, Pinterest, Inc.  All rights reserved.
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//

#import <AsyncDisplayKit/ASCache.h>
#import <AsyncDisplayKit/ASInternalHelpers.h>
#import <AsyncDisplayKit/ASLog.h>

#import <mutex>
#import <unordered_map>

using namespace std;

@implementation ASCache {
  mutex _m;
  condition_variable _c;
  CFMutableBagRef _workingOnKeys;
  NSUInteger _workingOnKeysCount;
  
#if ASCachingLogEnabled
  NSUInteger _hitCount;
  NSUInteger _missCount;
#endif
}

- (instancetype)init
{
  if (self = [super init]) {
    // Custom callbacks to avoid retain/releases. The key will be retained elsewhere.
    CFBagCallBacks cb = kCFTypeBagCallBacks;
    cb.release = NULL;
    cb.retain = NULL;
    _workingOnKeys = CFBagCreateMutable(NULL, 0, &cb);
  }
  return self;
}

- (void)dealloc
{
  CFRelease(_workingOnKeys);
}

// If cache logging is on, override this method and track stats.
#if ASCachingLogEnabled
- (id)objectForKey:(id)key
{
  id result = [super objectForKey:key];
  
  {
    lock_guard<mutex> l(_m);
    if (result) {
      _hitCount += 1;
    } else {
      _missCount += 1;
    }
    NSUInteger totalReads = _hitCount + _missCount;
    if (totalReads % 10 == 0) {
      as_log_info(ASCachingLog(), "%@ hit rate: %d/%d (%.2f%%)", self.name.length ? self.name : self.debugDescription, _hitCount, totalReads, 100.0 * (_hitCount / (double)totalReads));
    }
  }
  
  return result;
}
#endif

- (id)objectForKey:(id)key constructedWithBlock:(id (^)(id))block
{
  // First try = no lock.
  if (id result = [self objectForKey:key]) {
    return result;
  }
  
  while (true) {
    {
      unique_lock<mutex> l(_m);
      CFBagAddValue(_workingOnKeys, (__bridge CFTypeRef)key);
      CFIndex newCount = CFBagGetCount(_workingOnKeys);
      if (newCount > _workingOnKeysCount) {
        // The count went up when we added this key.
        // That means it wasn't there before and we're now
        // responsible for working on it. Break and get to work.
        _workingOnKeysCount = newCount;
        break;
      } else {
        // Someone else is working on it. This is unlikely.
        // Remove our entry and wait for the bag to have 0 entries
        // of this value.
        CFBagRemoveValue(_workingOnKeys, (__bridge CFTypeRef)key);
        while (CFBagContainsValue(_workingOnKeys, (__bridge CFTypeRef)key)) {
          _c.wait(l);
        }
      }
    }
    
    // If we got here, then we waited.
    // Now we should try to get the value.
    // In the unlikely event that the value is already
    // evicted, just loop around and try again.
    if (id result = [self objectForKey:key]) {
      return result;
    }
  }
  
  // If we got to here, then we have put the first entry for the key into the working set
  // and we're now responsible for making the value and notifying any waiters.
  id createdResult = block(key);
  
  static dispatch_queue_t notifyQueue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    notifyQueue = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);
  });
  dispatch_async(notifyQueue, ^{
    [self setObject:createdResult forKey:key];
    
    // Remove the value from the bag, and decrement our count.
    // We know the count will go down because we only
    {
      lock_guard<mutex> l(_m);
      CFBagRemoveValue(_workingOnKeys, (__bridge CFTypeRef)key);
      _workingOnKeysCount -= 1;
    }
    
    _c.notify_all();
  });
  return createdResult;
}

@end
