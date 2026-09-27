import Foundation

typealias TestClosure = () throws -> Void

@main
struct TestRunner {
    static func main() {
        Log.logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmb-tests-\(ProcessInfo.processInfo.processIdentifier).log")
        var passed = 0
        var failed = 0
        var failedNames: [String] = []

        let exclude = ExcludeFilterTests()
        let retention = RetentionTests()
        let config = ConfigParserTests()
        let backup = BackupEngineTests()
        let hardLinker = HardLinkerTests()
        let protection = RightsManagementTests()
        let scanner = FileScannerTests()
        let hidden = HiddenDiscoveryTests()
        let tree = TreeSelectionTests()
        let cleanup = SnapshotCleanupTests()

        let suites: [(String, TestClosure)] = [
            ("Cleanup.ageBoundaries", cleanup.test_ageBoundariesAndPreview),
            ("Cleanup.onlySnapshots", cleanup.test_latestAndNonSnapshotsSurvive),
            ("Cleanup.hardLinks", cleanup.test_hardLinksAndOriginalSurvive),
            ("Cleanup.lockAndCancel", cleanup.test_lockAndCancellation),
            ("Cleanup.legacyAndDestination", cleanup.test_legacyLockAndInvalidDestination),
            ("Cleanup.failures", cleanup.test_changedPreviewAndDeletionFailure),
            ("Cleanup.emptyAndSingle", cleanup.test_emptyAndSingleBackup),
            ("Cleanup.cliOptions", cleanup.test_cliOptions),
            ("ExcludeFilter.mandatoryCaches", exclude.test_mandatoryCachesWithOldConfig),
            ("ExcludeFilter.nestedPaths", exclude.test_nestedMultiComponentPatterns),
            ("FileScanner.explicitExclusions", scanner.test_explicitSourcesCannotBypassExclusions),
            ("ExcludeFilter.wildcardStar", exclude.test_wildcardStar),
            ("ExcludeFilter.wildcardQuestion", exclude.test_wildcardQuestion),
            ("ExcludeFilter.componentMatch", exclude.test_componentMatch),
            ("ExcludeFilter.pathPrefixMatch", exclude.test_pathPrefixMatch),
            ("ExcludeFilter.notExcluded", exclude.test_notExcluded),
            ("ExcludeFilter.directorySkip", exclude.test_directorySkip),
            ("ExcludeFilter.dotPatterns", exclude.test_dotPatterns),
            ("ExcludeFilter.checkoutsMandatory", exclude.test_checkoutsAreMandatoryExcludedEvenWithOldConfig),
            ("ExcludeFilter.pluginCacheDirMandatory", exclude.test_pluginCacheDirIsMandatoryExcludedDistinctFromDotCache),
            ("HiddenDiscovery.deniedCacheNames", hidden.test_deniedCacheNames),
            ("HiddenDiscovery.realConfigSurvives", hidden.test_realConfigSurvives),
            ("HiddenDiscovery.deniedPaths", hidden.test_deniedPaths),
            ("HiddenDiscovery.secretsStayOptIn", hidden.test_secretsStayOptIn),
            ("HiddenDiscovery.pruneRedundant", hidden.test_pruneRedundant),
            ("HiddenDiscovery.sizeIgnoresExcludedContent", hidden.test_sizeIgnoresExcludedContent),
            ("HiddenDiscovery.claudeScriptsNotForbidden", hidden.test_claudeScriptsIsBackedUpNotForbidden),
            ("HiddenDiscovery.launchAgentsDiscovered", hidden.test_launchAgentsAreDiscovered),
            ("HiddenDiscovery.checkoutsIsDenied", hidden.test_checkoutsIsADeniedName),
            ("HiddenDiscovery.cloudStorageForbiddenByDefault", hidden.test_cloudStorageForbiddenByDefault),
            ("HiddenDiscovery.cloudStorageAllowedOnlyWithOptIn", hidden.test_cloudStorageAllowedOnlyWithExplicitOptIn),
            ("Retention.parseValid", retention.test_parseBackupName_valid),
            ("Retention.parseInvalid", retention.test_parseBackupName_invalid),
            ("Retention.keepLatest", retention.test_alwaysKeepLatest),
            ("Retention.hourly", retention.test_hourlyRetention),
            ("Retention.dryRun", retention.test_dryRunNoDeletion),
            ("Retention.monthlyForever", retention.test_monthlyForever),
            ("Config.parseFull", config.test_parseFullConfig),
            ("Config.defaults", config.test_defaultRetention),
            ("Config.comments", config.test_commentsIgnored),
            ("Config.roundTrip", config.test_roundTrip),
            ("Config.legacyMigration", config.test_legacyConfigMigration),
            ("Config.protectionPreference", config.test_protectionPreferenceRoundTripAndMigration),
            ("TreeSelection.protectionToggle", tree.test_protectionToggleIsIndependentAndConfirmed),
            ("TreeSelection.addCustomPathRejectsForbidden", tree.test_addCustomPathRejectsForbiddenPaths),
            ("BackupEngine.naming", backup.test_snapshotNaming),
            ("BackupEngine.inProgress", backup.test_inProgressPrefix),
            ("BackupEngine.statusFormat", backup.test_statusFileFormat),
            ("HardLinker.sameFile", hardLinker.test_sameFileSameSizeMtime),
            ("HardLinker.diffSize", hardLinker.test_differentSize),
            ("HardLinker.hardLink", hardLinker.test_hardLinkCreation),
            ("HardLinker.copyFile", hardLinker.test_copyFileCreation),
            ("Protection.containers", protection.test_protectedContainersAcrossFormats),
            ("Protection.compound", protection.test_compoundProtectionAndPasswordDistinction),
            ("Protection.pdf", protection.test_pdfProtectionAndOrdinaryText),
            ("Protection.ordinaryIncluded", protection.test_ordinaryOfficeAndOtherFilesRemainIncluded),
            ("Protection.copyAndLink", protection.test_preferenceBeforeCopyAndHardLink),
            ("Protection.inspectionFailures", protection.test_inspectionFailuresAreNotClaimedAsProtection),
            ("Protection.permissionErrors", protection.test_permissionErrorsKeepActionableCategory),
            ("Protection.reporting", protection.test_skipsAreReportedSeparately),
            ("FileScanner.excludedFileKeepsSibling", scanner.test_excludedFileDoesNotSwallowSiblingDirectory),
            ("FileScanner.excludedDirPruned", scanner.test_excludedDirectoryIsStillPruned),
            ("FileScanner.multipleExcludedFiles", scanner.test_multipleExcludedFilesBeforeDirectory)
        ]

        print("🧪 Running RustyMacBackup tests (\(suites.count) total)...")
        for (name, test) in suites {
            do {
                try test()
                passed += 1
                print("  ✅ \(name)")
            } catch {
                failed += 1
                failedNames.append(name)
                print("  ❌ \(name): \(error)")
            }
        }

        print("\n\(passed + failed) tests, \(passed) passed, \(failed) failed")
        if !failedNames.isEmpty {
            print("Failed: \(failedNames.joined(separator: ", "))")
            exit(1)
        }
    }
}
