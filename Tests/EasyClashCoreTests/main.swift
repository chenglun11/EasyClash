import Foundation
var assertions=0
func failure(_ message:String,file:StaticString,line:UInt)->Never {fputs("FAIL \(file):\(line): \(message)\n",stderr);exit(1)}
func expectTrue(_ value:@autoclosure () throws -> Bool,file:StaticString=#filePath,line:UInt=#line) {assertions+=1;do {if try !value() {failure("expected true",file:file,line:line)}} catch {failure("unexpected throw",file:file,line:line)}}
func expectFalse(_ value:@autoclosure () throws -> Bool,file:StaticString=#filePath,line:UInt=#line) {expectTrue(try !value(),file:file,line:line)}
func expectEqual<T:Equatable>(_ a:@autoclosure () throws -> T,_ b:@autoclosure () throws -> T,file:StaticString=#filePath,line:UInt=#line) {expectTrue(try a()==b(),file:file,line:line)}
func expectNil<T>(_ value:@autoclosure () throws -> T?,file:StaticString=#filePath,line:UInt=#line) {expectTrue(try value()==nil,file:file,line:line)}
func expectNotNil<T>(_ value:@autoclosure () throws -> T?,file:StaticString=#filePath,line:UInt=#line) {expectTrue(try value() != nil,file:file,line:line)}
func expectThrows<T>(_ value:@autoclosure () throws -> T,file:StaticString=#filePath,line:UInt=#line) {assertions+=1;do {_ = try value();failure("expected throw",file:file,line:line)} catch {}}
func expectNoThrow<T>(_ value:@autoclosure () throws -> T,file:StaticString=#filePath,line:UInt=#line) {assertions+=1;do {_ = try value()} catch {failure("unexpected throw",file:file,line:line)}}
func unwrap<T>(_ value:T?) throws -> T {guard let value else {throw NSError(domain:"test",code:1)};return value}
let tests=CoreTests()
do {
    try tests.testUnconfiguredLaunchAndRedactedReport()
    tests.testVPNRouteRejectsClashDefaultAndProcessOnly()
    try tests.testOverlayRemovesPublicRaceAndPreservesOtherUserSettings()
    tests.testWhitelistFailsWithoutMutation()
    try tests.testSettingsRejectInjectionAndSupportMultipleDomains()
    tests.testLeaseExpiresAfterCrashHangClockRollbackAndDeletion()
    try tests.testLogContainsOnlyEventCode()
    tests.testRouteTableScopeAndInterfaceChanges()
    try tests.testBackgroundCommandsExitAndTimeout()
    try clientTests()
    try integrationTests()
    try flClashIntegrationTests()
    print("PASS: public source tests, \(assertions) assertions")
} catch {fputs("Unexpected test error: \(error.localizedDescription)\n",stderr);exit(1)}
