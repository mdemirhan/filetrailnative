// Ports apps/desktop/src/main/bootstrap/folderSizeAdjust.test.ts
import Foundation
import Testing

@testable import FTFileSystem

private let disk: Int64 = 16
private let otherDisk: Int64 = 17
private let trash = "/Users/demo/.Trash"

/// Stored by one measurement unless said otherwise.
private func sized(
    _ sizeBytes: Int64, _ fileCount: Int = 1, _ folderCount: Int = 0, dev: Int64 = disk, measurement: Int = 1
) -> FolderSizeStats {
    FolderSizeStats(
        sizeBytes: sizeBytes, diskBytes: sizeBytes * 2, fileCount: fileCount, folderCount: folderCount, dev: dev,
        measurement: measurement)
}

/// Stored by a measurement of its own, made later.
private func measuredAgain(_ sizeBytes: Int64, _ fileCount: Int = 1, _ folderCount: Int = 0) -> FolderSizeStats {
    sized(sizeBytes, fileCount, folderCount, dev: disk, measurement: 2)
}

private func file(_ sizeBytes: Int64, dev: Int64 = disk) -> ItemSize {
    ItemSize(kind: .file, sizeBytes: sizeBytes, diskBytes: sizeBytes * 2, dev: dev)
}

private func folder(dev: Int64 = disk) -> ItemSize {
    ItemSize(kind: .folder, sizeBytes: 0, diskBytes: 0, dev: dev)
}

private func deleted(_ path: String, _ item: ItemSize?) -> RemovedItem {
    RemovedItem(path: path, item: item, intoHomeTrash: false)
}

private func trashed(_ path: String, _ item: ItemSize?, _ intoHomeTrash: Bool? = true) -> RemovedItem {
    RemovedItem(path: path, item: item, intoHomeTrash: intoHomeTrash)
}

private func adjust(
    _ entries: [String: FolderSizeStats], _ removals: [RemovedItem], counted: Bool? = nil
) -> [String: FolderSizeStats] {
    let cache = FolderSizeCache()
    for (path, entry) in entries {
        cache.store(path, entry)
    }
    FolderSizeAdjust.adjustForRemovals(cache, removals, HomeTrash(path: trash, counted: counted))
    return Dictionary(uniqueKeysWithValues: cache.entries().map { ($0.path, $0.stats) })
}

@Suite struct FolderSizeAdjustTests {
    // T-3c0430d8
    @Test func takesADeletedFileOffEveryMeasuredFolderThatHeldIt() {
        #expect(
            adjust(
                [
                    "/Users/demo": sized(1_000, 10, 3),
                    "/Users/demo/Downloads": sized(600, 6, 1),
                    "/Users/demo/Downloads/zips": sized(500, 5),
                    "/Users/demo/Music": sized(300, 3),
                ],
                [deleted("/Users/demo/Downloads/zips/a.zip", file(200))])
                == [
                    "/Users/demo": sized(800, 9, 3),
                    "/Users/demo/Downloads": sized(400, 5, 1),
                    "/Users/demo/Downloads/zips": sized(300, 4),
                    "/Users/demo/Music": sized(300, 3),
                ])
    }

    // T-ea6f97e9
    @Test func takesADeletedFolderOffWithEverythingInItAndForgetsItsOwnSizes() {
        // 4 files, and the folder with the 1 folder inside it.
        #expect(
            adjust(
                [
                    "/Users/demo": sized(1_000, 10, 4),
                    "/Users/demo/Old": sized(400, 4, 1),
                    "/Users/demo/Old/inner": sized(100, 1),
                ],
                [deleted("/Users/demo/Old", folder())]) == ["/Users/demo": sized(600, 6, 2)])
    }

    // T-dd18e601
    @Test func takesOffNothingForItemsAMeasurementDoesntCountLikeAPipe() {
        let entries = ["/Users/demo": sized(1_000, 10)]
        #expect(
            adjust(
                entries,
                [deleted("/Users/demo/pipe", ItemSize(kind: .other, sizeBytes: 0, diskBytes: 0, dev: disk))])
                == entries)
    }

    // T-ab3b624e
    @Test func forgetsTheFoldersThatHeldWhatCouldntBeReadFirstOrMeasured() {
        let entries = [
            "/Users/demo": sized(1_000, 10, 2),
            "/Users/demo/Music": sized(300, 3),
        ]
        // Gone before it was read.
        #expect(
            adjust(entries, [deleted("/Users/demo/a.txt", nil)]) == ["/Users/demo/Music": sized(300, 3)])
        // A folder whose own size isn't known.
        #expect(
            adjust(entries, [deleted("/Users/demo/Old", folder())]) == ["/Users/demo/Music": sized(300, 3)])
    }

    // T-db4495e6
    @Test func forgetsAFolderWhoseMeasurementMayNotHaveReachedTheItem() {
        // Nothing known for Private: it may not have been readable when Users/demo was measured.
        #expect(
            adjust(
                [
                    "/Users/demo": sized(1_000, 10, 2),
                    "/Users/demo/Private/notes": sized(100, 1),
                ],
                [deleted("/Users/demo/Private/notes/a.txt", file(40))])
                == ["/Users/demo/Private/notes": sized(60, 0)])
    }

    // T-6aa64f5c
    @Test func leavesAFolderMeasuredOnAnotherDiskWhoseMeasurementStoppedAtTheDisk() {
        #expect(
            adjust(
                [
                    "/": sized(5_000, 50, 10, dev: otherDisk),
                    "/Users": sized(1_000, 10, 2),
                    "/Users/demo": sized(1_000, 10, 1),
                ],
                [deleted("/Users/demo/a.txt", file(100))])
                == [
                    "/": sized(5_000, 50, 10, dev: otherDisk),
                    "/Users": sized(900, 9, 2),
                    "/Users/demo": sized(900, 9, 1),
                ])
    }

    // T-629cdeb7
    @Test func countsAFolderOnAnotherDiskAMountPointAsOneFolderAndNothingInside() {
        #expect(
            adjust(
                ["/Users/demo": sized(1_000, 10, 3)],
                [deleted("/Users/demo/mounted", folder(dev: otherDisk))])
                == ["/Users/demo": sized(1_000, 10, 2)])
    }

    // T-48af9715
    @Test func forgetsAFolderItsChangeWouldTakeBelowZero() {
        #expect(
            adjust(["/Users/demo": sized(100, 1)], [deleted("/Users/demo/a.txt", file(500))]).isEmpty)
    }

    // Folder 100 MB with Inner 50 MB in it; Inner grew to 80 MB and was measured again on its own. Taking 80 MB
    // off Folder's 100 left 20 MB where 50 MB remained.
    // T-db1e3133
    @Test func forgetsAFolderRatherThanTakeOffAFolderInsideMeasuredAgainSince() {
        #expect(
            adjust(
                [
                    "/Users/demo/Folder": sized(100, 10, 1),
                    "/Users/demo/Folder/Inner": measuredAgain(80, 8),
                ],
                [deleted("/Users/demo/Folder/Inner", folder())]).isEmpty)
    }

    // T-89ca3d02
    @Test func forgetsAFolderRatherThanReachTheItemThroughAFolderMeasuredOnItsOwn() {
        // "/" was measured, and /Users measured again by itself later.
        #expect(
            adjust(
                [
                    "/": sized(9_000, 90, 20),
                    "/Users": measuredAgain(1_000, 10, 2),
                    "/Users/demo": measuredAgain(1_000, 10, 1),
                ],
                [deleted("/Users/demo/a.txt", file(100))])
                == [
                    "/Users": measuredAgain(900, 9, 2),
                    "/Users/demo": measuredAgain(900, 9, 1),
                ])
    }

    // T-985ec077
    @Test func takesAMeasuredFolderOffTheMeasuredFolderHoldingItAndForgetsItsOwnSizes() {
        #expect(
            adjust(
                [
                    "/Users/demo": sized(1_000, 10, 3),
                    "/Users/demo/Work": sized(400, 4, 1),
                    "/Users/demo/Work/inner": sized(100, 1),
                ],
                [deleted("/Users/demo/Work", folder())]) == ["/Users/demo": sized(600, 6, 1)])
        // Measured on its own after the folder holding it, it may not be what that one counted.
        #expect(
            adjust(
                [
                    "/Users/demo": sized(1_000, 10, 3),
                    "/Users/demo/Work": measuredAgain(400, 4, 1),
                ],
                [deleted("/Users/demo/Work", folder())]).isEmpty)
    }

    // A link to a folder is counted as itself and never walked: what is reached through it was never counted by
    // the folders holding the link.
    // T-d52535d2
    @Test func forgetsTheFoldersHoldingALinkThatAnItemWasRemovedThrough() {
        #expect(
            adjust(
                [
                    "/Users/demo": sized(1_000, 10, 3),
                    "/Users/demo/link/notes": measuredAgain(300, 3),
                ],
                [deleted("/Users/demo/link/notes/a.txt", file(100))])
                == ["/Users/demo/link/notes": measuredAgain(200, 2)])
    }

    // T-a1acc72e
    @Test func takesSeveralItemsOffOneAfterAnother() {
        #expect(
            adjust(
                ["/Users/demo": sized(1_000, 10)],
                [
                    deleted("/Users/demo/a.txt", file(100)),
                    deleted("/Users/demo/b.txt", file(200)),
                ]) == ["/Users/demo": sized(700, 8)])
    }

    @Suite struct MovedToTheTrash {
        let entries: [String: FolderSizeStats] = [
            "/Users/demo": sized(1_000, 10, 3),
            "/Users/demo/Downloads": sized(600, 6),
            trash: sized(50, 1),
        ]

        // T-6ed18d4a
        @Test func keepsTheSizeOfAFolderThatCountedTheTrashAndAddsToTheTrash() {
            #expect(
                adjust(entries, [trashed("/Users/demo/Downloads/a.zip", file(200))], counted: true)
                    == [
                        "/Users/demo": sized(1_000, 10, 3),
                        "/Users/demo/Downloads": sized(400, 5),
                        trash: sized(250, 2),
                    ])
        }

        // T-52c8a54b
        @Test func takesItOffAFolderThatCouldntReadTheTrash() {
            var unreadable = entries
            unreadable[trash] = nil
            #expect(
                adjust(unreadable, [trashed("/Users/demo/Downloads/a.zip", file(200))], counted: false)
                    == [
                        "/Users/demo": sized(800, 9, 3),
                        "/Users/demo/Downloads": sized(400, 5),
                    ])
        }

        // T-7a063fd6
        @Test func forgetsTheFoldersHoldingTheTrashWhileItIsntKnownWhetherItWasRead() {
            #expect(
                adjust(entries, [trashed("/Users/demo/Downloads/a.zip", file(200))], counted: nil)
                    == [
                        "/Users/demo/Downloads": sized(400, 5),
                        // Its own size is known: the item lands at its top.
                        trash: sized(250, 2),
                    ])
        }

        // T-3fced040
        @Test func addsWhatComesFromOutsideTheHomeFolderToTheFoldersHoldingTheTrash() {
            #expect(
                adjust(
                    [
                        "/": sized(9_000, 90, 20),
                        "/Users": sized(1_000, 10, 4),
                        "/Users/demo": sized(1_000, 10, 3),
                        "/opt": sized(500, 5, 1),
                        "/opt/tools": sized(300, 3),
                    ],
                    [trashed("/opt/tools/old", file(100))], counted: true)
                    == [
                        // Moved within what it counted.
                        "/": sized(9_000, 90, 20),
                        "/Users": sized(1_100, 11, 4),
                        "/Users/demo": sized(1_100, 11, 3),
                        "/opt": sized(400, 4, 1),
                        "/opt/tools": sized(200, 2),
                    ])
        }

        // T-e7fd8fe4
        @Test func forgetsTheFoldersHoldingTheTrashWhenItIsntKnownWhereAnItemWent() {
            #expect(
                adjust(entries, [trashed("/Users/demo/Downloads/a.zip", nil, nil)], counted: true).isEmpty)
        }

        /// Deleting from the Trash: whether the folders holding it counted the item depends on whether their
        /// measurement walked into the Trash, which the sizes on the way show.
        @Suite struct DeletedFromTheTrash {
            let entries: [String: FolderSizeStats] = [
                "/Users/demo": sized(1_000, 10, 3),
                "/Users/demo/Downloads": sized(600, 6),
                trash: sized(50, 1),
            ]
            let inTrash = "\(trash)/old.zip"

            // T-fc36d4d5
            @Test func takesItOffTheTrashAndTheFoldersThatCountedTheTrash() {
                for counted in [true, false, nil] as [Bool?] {
                    #expect(
                        adjust(entries, [deleted(inTrash, file(20))], counted: counted)
                            == [
                                "/Users/demo": sized(980, 9, 3),
                                "/Users/demo/Downloads": sized(600, 6),
                                trash: sized(30, 0),
                            ])
                }
            }

            // T-13e3ec68
            @Test func forgetsTheFoldersHoldingTheTrashWhenItHasNoSizeOfTheSameMeasurement() {
                var unread = entries
                unread[trash] = nil
                for counted in [true, false, nil] as [Bool?] {
                    #expect(
                        adjust(unread, [deleted(inTrash, file(20))], counted: counted)
                            == ["/Users/demo/Downloads": sized(600, 6)])
                    var again = unread
                    again[trash] = measuredAgain(50, 1)
                    #expect(
                        adjust(again, [deleted(inTrash, file(20))], counted: counted)
                            == ["/Users/demo/Downloads": sized(600, 6), trash: measuredAgain(30, 0)])
                }
            }
        }

        // T-4dd5fe3e
        @Test func takesOffWhatWentToAnotherDisksTrashWhichNoMeasurementReads() {
            #expect(
                adjust(entries, [trashed("/Users/demo/Downloads/a.zip", file(200), false)], counted: true)
                    == [
                        "/Users/demo": sized(800, 9, 3),
                        "/Users/demo/Downloads": sized(400, 5),
                        trash: sized(50, 1),
                    ])
        }
    }
}
