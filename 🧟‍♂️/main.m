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

void foo(void) {
    __unsafe_unretained OTQ *obj = nil;
    @autoreleasepool {
        obj = [OTQ new];
    }
    [obj description];
}

void bar(void) {
    foo();
}

int main(int argc, const char * argv[]) {
    [KTBetterZombie traceObjectWithClassName:"OTQ"];
    bar();
    return 0;
}
