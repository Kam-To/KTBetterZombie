//
//  main.m
//  🧟‍♂️
//
//  Created by Kam on 2020/8/19.
//

#import <Foundation/Foundation.h>
#import "KTBetterZombie.h"

@interface OTQ : NSObject
@end
@implementation OTQ
@end

void foo() {
    __unsafe_unretained OTQ *obj = nil;
    @autoreleasepool {
        obj = [OTQ new];
    }
    [obj description];
}

void bar() {
    foo();
}

int main(int argc, const char * argv[]) {
    [KTBetterZombie action];
    bar();
    return 0;
}
