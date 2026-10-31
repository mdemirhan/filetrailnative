// Stands for packages/contracts/src/ipc.test.ts and schemaFreeImports.test.ts, which have no Swift counterpart
import Testing

@testable import FTFoundation

// N/A T-93a74c61 T-5caca6fd T-4ac8d32f T-67c58c14 T-91dad5bd T-95dc1c09 T-dbf6cd0b T-c07bc297 T-69f61f40 T-beee33b2
// N/A T-7c76877a T-bf79f326 T-94ee5982 T-724f4640 T-459aaca2 T-94edc241 T-d602e46f T-6dfd63c0 T-c55bfd80
// N/A T-a5e597ca T-ee3bed1d T-e2d9e75d T-064a7713 T-f7822220 T-e23d4982 T-a22e008c
// IPC schema validation; replaced by Swift types. The name rules T-4ac8d32f and T-67c58c14 check live in ItemNames,
// tested by ItemNamesTests, and the 100,000-path bound is Limits.maxPathsPerRequest.
