#import <XCTest/XCTest.h>

// The pinned Flutter SDK supplies this driver in the test host's integration_test
// plugin. Runtime lookup avoids linking a second copy of its singleton into this
// XCTest bundle. The selector matches FLTIntegrationTestRunner.h in that SDK.
@interface NSObject (MinutroveIntegrationDriver)
- (void)testIntegrationTestWithResults:
    (void (^)(SEL testSelector, BOOL success, NSString *failureMessage))callback;
@end

@interface IntegrationTests : XCTestCase
@end

@implementation IntegrationTests
- (void)testDartIntegrationSuite {
  Class driverClass = NSClassFromString(@"FLTIntegrationTestRunner");
  XCTAssertNotNil(driverClass, @"Flutter integration_test driver must be in the test host");
  if (driverClass == Nil) return;
  NSObject *driver = [[driverClass alloc] init];
  XCTAssertTrue([driver respondsToSelector:@selector(testIntegrationTestWithResults:)]);
  if (![driver respondsToSelector:@selector(testIntegrationTestWithResults:)]) return;
  __block NSUInteger testCount = 0;
  [driver testIntegrationTestWithResults:^(SEL selector, BOOL success, NSString *failure) {
    testCount += 1;
    NSLog(@"Dart integration result: %@ — %@", NSStringFromSelector(selector), success ? @"passed" : @"failed");
    XCTAssertTrue(success, @"%@: %@", NSStringFromSelector(selector), failure);
  }];
  XCTAssertGreaterThan(testCount, 0u, @"The Dart integration suite must execute tests");
}
@end
