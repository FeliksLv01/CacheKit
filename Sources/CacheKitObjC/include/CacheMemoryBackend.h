#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CacheMemoryBackend : NSObject

- (instancetype)initWithCountLimit:(NSUInteger)countLimit costLimit:(NSUInteger)costLimit;
- (nullable id)objectForKey:(NSString *)key now:(NSTimeInterval)now;
- (void)setObject:(id)object
            forKey:(NSString *)key
              cost:(NSUInteger)cost
         expiresAt:(NSTimeInterval)expiresAt;
- (void)removeObjectForKey:(NSString *)key;
- (void)removeAllObjects;
- (NSUInteger)count;

@end

NS_ASSUME_NONNULL_END
