#import "CacheMemoryBackend.h"

#import <math.h>
#import <os/lock.h>
#import <time.h>

static inline NSTimeInterval CacheCurrentTimestamp(void) {
    struct timespec time;
    clock_gettime(CLOCK_REALTIME, &time);
    return (NSTimeInterval)time.tv_sec + (NSTimeInterval)time.tv_nsec / 1000000000.0;
}

@interface CacheMemoryNode : NSObject

@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) id object;
@property (nonatomic) NSUInteger cost;
@property (nonatomic) NSTimeInterval expiresAt;
@property (nonatomic, unsafe_unretained, nullable) CacheMemoryNode *previous;
@property (nonatomic, unsafe_unretained, nullable) CacheMemoryNode *next;

@end


@implementation CacheMemoryNode
@end


@implementation CacheMemoryBackend {
    os_unfair_lock _lock;
    CFMutableDictionaryRef _nodes;
    CacheMemoryNode *_head;
    CacheMemoryNode *_tail;
    NSUInteger _totalCost;
    NSUInteger _countLimit;
    NSUInteger _costLimit;
}

- (instancetype)initWithCountLimit:(NSUInteger)countLimit costLimit:(NSUInteger)costLimit {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _countLimit = countLimit;
        _costLimit = costLimit;
        _nodes = CFDictionaryCreateMutable(
            kCFAllocatorDefault,
            0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks
        );
    }
    return self;
}

- (void)dealloc {
    if (_nodes) {
        CFRelease(_nodes);
    }
}

- (id)objectForKey:(NSString *)key now:(NSTimeInterval)now {
    CacheMemoryNode *removedNode = nil;
    id object = nil;
    os_unfair_lock_lock(&_lock);
    CacheMemoryNode *node = (CacheMemoryNode *)CFDictionaryGetValue(_nodes, (__bridge const void *)key);
    if (node && !isnan(node.expiresAt) && node.expiresAt <= (isnan(now) ? CacheCurrentTimestamp() : now)) {
        removedNode = node;
        [self removeNode:node];
    } else if (node) {
        [self moveToHead:node];
        object = node.object;
    }
    os_unfair_lock_unlock(&_lock);
    (void)removedNode;
    return object;
}

- (void)setObject:(id)object
            forKey:(NSString *)key
              cost:(NSUInteger)cost
         expiresAt:(NSTimeInterval)expiresAt {
    id oldObject = nil;
    NSMutableArray<CacheMemoryNode *> *removedNodes = nil;
    os_unfair_lock_lock(&_lock);
    CacheMemoryNode *node = (CacheMemoryNode *)CFDictionaryGetValue(_nodes, (__bridge const void *)key);
    if (node) {
        oldObject = node.object;
        _totalCost -= node.cost;
        node.object = object;
        node.cost = cost;
        node.expiresAt = expiresAt;
        _totalCost += cost;
        [self moveToHead:node];
    } else {
        node = [CacheMemoryNode new];
        node.key = key;
        node.object = object;
        node.cost = cost;
        node.expiresAt = expiresAt;
        CFDictionarySetValue(_nodes, (__bridge const void *)node.key, (__bridge const void *)node);
        _totalCost += cost;
        [self insertAtHead:node];
    }

    while ((_countLimit > 0 && CFDictionaryGetCount(_nodes) > _countLimit) ||
           (_costLimit > 0 && _totalCost > _costLimit)) {
        CacheMemoryNode *victim = _tail;
        if (!victim) {
            break;
        }
        if (!removedNodes) {
            removedNodes = [NSMutableArray array];
        }
        [removedNodes addObject:victim];
        [self removeNode:victim];
    }
    os_unfair_lock_unlock(&_lock);
    (void)oldObject;
    (void)removedNodes;
}

- (void)removeObjectForKey:(NSString *)key {
    CacheMemoryNode *removedNode = nil;
    os_unfair_lock_lock(&_lock);
    CacheMemoryNode *node = (CacheMemoryNode *)CFDictionaryGetValue(_nodes, (__bridge const void *)key);
    if (node) {
        removedNode = node;
        [self removeNode:node];
    }
    os_unfair_lock_unlock(&_lock);
    (void)removedNode;
}

- (void)removeAllObjects {
    NSMutableArray<CacheMemoryNode *> *removedNodes = [NSMutableArray array];
    os_unfair_lock_lock(&_lock);
    CacheMemoryNode *node = _head;
    while (node) {
        [removedNodes addObject:node];
        node = node.next;
    }
    CFDictionaryRemoveAllValues(_nodes);
    _head = nil;
    _tail = nil;
    _totalCost = 0;
    os_unfair_lock_unlock(&_lock);
    (void)removedNodes;
}

- (NSUInteger)count {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = (NSUInteger)CFDictionaryGetCount(_nodes);
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (void)insertAtHead:(CacheMemoryNode *)node {
    node.previous = nil;
    node.next = _head;
    _head.previous = node;
    _head = node;
    if (!_tail) {
        _tail = node;
    }
}

- (void)moveToHead:(CacheMemoryNode *)node {
    if (_head == node) {
        return;
    }
    [self detachNode:node];
    [self insertAtHead:node];
}

- (void)removeNode:(CacheMemoryNode *)node {
    CFDictionaryRemoveValue(_nodes, (__bridge const void *)node.key);
    _totalCost -= node.cost;
    [self detachNode:node];
}

- (void)detachNode:(CacheMemoryNode *)node {
    CacheMemoryNode *previous = node.previous;
    CacheMemoryNode *next = node.next;
    previous.next = next;
    next.previous = previous;
    if (_head == node) {
        _head = next;
    }
    if (_tail == node) {
        _tail = previous;
    }
    node.previous = nil;
    node.next = nil;
}

@end
