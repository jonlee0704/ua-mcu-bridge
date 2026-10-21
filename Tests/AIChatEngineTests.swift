// ==============================================================================
// Copyright (c) 2026 S&D A11y Studio. All Rights Reserved.
//
// AI Studio Co-Producer: Chat Dialog & Natural Language Mixer Command Tests
// ==============================================================================

import Foundation
import AppKit

public final class AIChatEngineTests {
    public static func runAll() {
        print("\n\u{001B}[1;36m================================================================")
        print(" [TEST SUITE 5] AI Co-Producer Chat Dialog & Natural Language Commands")
        print("================================================================\u{001B}[0m")

        testFineButtonShortPressVsLongPress()
        testOverloadNaturalLanguageQuery()
        testSetAllInfinityAndUndoRedo()
        testSendMuteNaturalLanguageQuery()
        testGeminiApiKeyAnyFormatSupport()
        testZeroInputChannelsNaturalLanguageQuery()
        testActiveSignalAndConsoleSummaryQueries()
        testHardwareGuideAndGestureQueries()
        testFullChannelListInventoryQuery()
        testQueryCancellationAndStopExecution()
        testPromptSuggestionsCardAndChips()
        testTimedListeningIntentParsing()
        testTimedListeningExecutionDataPointsAndSummary()
        testDirectTactileAndUADConsoleControlCommands()
        testUserPromptBubbleZeroClippingAndRichFormatting()
        testGeminiCardIconOnlyCopyAndMoreMenu()
        testLocalCueInformationAndControl()
        testLocalPluginInformationAndControl()
        testChatInputFieldCopyPasteAndAIChatWindow()
        testPromptCatalogDataIntegrityAndCategories()
        testDynamicContextualSuggestionsGeneration()
        testPromptHelpPageUIAndQueryTrigger()
        testLocalLLMAndOllamaProviderConfiguration()
    }

    /// Test FINE button short press (normal 3-step cycle) vs long press (open chat window)
    public static func testFineButtonShortPressVsLongPress() {
        runTest("P0: FINE key short-press (<600ms) runs 3-step cycle; long-press opens chat") {
            let (mcu, _, _) = TestAudioFixture.makeMCUEngine(channelCount: 8)
            var chatOpened = false
            mcu.onOpenAIChatWindow = {
                chatOpened = true
            }

            // 1. Short press (<600ms): Note 70 down, then immediately up
            assertEqual(mcu.auditor.state, .idle, "Auditor initial state must be idle")
            mcu.handleMidiBytes([0x90, 70, 0x7F]) // Down
            mcu.handleMidiBytes([0x90, 70, 0x00]) // Up immediately
            assertFalse(chatOpened, "Short press must NOT trigger chat window")
            assertEqual(mcu.auditor.state, .listening, "Short press must advance auditor to listening state")

            // 2. Long press Note 70: Trigger long press
            mcu.triggerFineLongPress()
            assertTrue(chatOpened, "Long press must trigger onOpenAIChatWindow callback")
            assertTrue(mcu.fineLongPressTriggered, "fineLongPressTriggered flag must be active")

            // Releasing note 70 after long press must not re-trigger auditor cycle
            mcu.handleMidiBytes([0x90, 70, 0x00])
            assertEqual(mcu.auditor.state, .listening, "Release after long press must not alter auditor cycle")
            assertFalse(mcu.fineLongPressTriggered, "Flag must reset after release")

            // 3. SSL UF8 Physical FINE Button (Note 83): Long press opens chat
            chatOpened = false
            mcu.handleMidiBytes([0x90, 83, 0x7F]) // Note 83 Down
            mcu.triggerFineLongPress()
            assertTrue(chatOpened, "Note 83 long press must trigger onOpenAIChatWindow callback")
            assertTrue(mcu.fineLongPressTriggered, "fineLongPressTriggered flag must be active for Note 83")

            // Releasing Note 83 after long press resets flag cleanly without altering auditor
            mcu.handleMidiBytes([0x90, 83, 0x00])
            assertFalse(mcu.fineLongPressTriggered, "Flag must reset after Note 83 release")

            // 4. SSL UF8 Wheel rotation during Note 83 cancels long press and absorbs strobe
            chatOpened = false
            mcu.handleMidiBytes([0x90, 83, 0x7F]) // Note 83 Down
            mcu.handleMidiBytes([0x90, 46, 0x7F]) // Wheel rotated CCW
            mcu.handleMidiBytes([0x90, 83, 0x00]) // Note 83 Up
            assertFalse(chatOpened, "Wheel rotation during Note 83 must cancel long press")
        }
    }

    /// Test natural language query: "tell me channels in Overloaded"
    public static func testOverloadNaturalLanguageQuery() {
        runTest("P0: Natural Language: 'tell me channels in Overloaded' detects clipping") {
            let uad = UADClient()
            uad.channels = TestAudioFixture.makeChannels(count: 8)
            let auditor = AIAudioAuditor(uadClient: uad)
            let chat = AIChatEngine()

            // When no channels are clipping
            var reply1 = ""
            chat.processQuery(query: "tell me channels in Overloaded", uad: uad, auditor: auditor) { rep in
                reply1 = rep
            }
            assertTrue(reply1.contains("No channels are currently in Overload"), "Must report clean channels when none clipping")

            // Simulate clipping on channel 0 and 2
            uad.channels[0]?.meterClip = true
            uad.channels[0]?.meterPeak = 0.4
            uad.channels[2]?.meterClip = true
            uad.channels[2]?.meterPeak = 0.1

            var reply2 = ""
            chat.processQuery(query: "which tracks are clipping or overloaded?", uad: uad, auditor: auditor) { rep in
                reply2 = rep
            }
            assertTrue(reply2.contains("Overloaded Channels Detected"), "Must detect overloaded channels")
            assertTrue(reply2.contains("Ch 1"), "Must list Ch 1")
            assertTrue(reply2.contains("Ch 3"), "Must list Ch 3")
        }
    }

    /// Test natural language query: "set -infinite dB for all channels" + Undo & Redo
    public static func testSetAllInfinityAndUndoRedo() {
        runTest("P0: Natural Language: 'set -infinite dB for all channels' + Undo/Redo rollback") {
            let uad = UADClient()
            uad.channels = TestAudioFixture.makeChannels(count: 8)
            for ch in uad.channels.values {
                ch.fader = 0.75
            }
            let auditor = AIAudioAuditor(uadClient: uad)
            let chat = AIChatEngine()

            // 1. Set -infinite dB for all channels
            var replySet = ""
            chat.processQuery(query: "set -infinite dB for all channels", uad: uad, auditor: auditor) { rep in
                replySet = rep
            }
            assertTrue(replySet.contains("-infinity dB"), "Reply must confirm setting -inf dB")
            for ch in uad.channels.values {
                assertEqual(ch.fader, 0.0, "All faders must be at 0.0 (-144 dB)")
            }

            // 2. Undo (-1 step back in history)
            var replyUndo = ""
            chat.processQuery(query: "go back to -1 step back history", uad: uad, auditor: auditor) { rep in
                replyUndo = rep
            }
            assertTrue(replyUndo.contains("Undid"), "Reply must confirm undo operation")
            for ch in uad.channels.values {
                assertEqual(ch.fader, 0.75, "All faders must be restored to 0.75 after undo")
            }

            // 3. Redo
            var replyRedo = ""
            chat.processQuery(query: "redo", uad: uad, auditor: auditor) { rep in
                replyRedo = rep
            }
            assertTrue(replyRedo.contains("Redid"), "Reply must confirm redo operation")
            for ch in uad.channels.values {
                assertEqual(ch.fader, 0.0, "All faders must be re-applied to 0.0 after redo")
            }
        }
    }

    /// Test natural language query: "mute C2 level for System out"
    public static func testSendMuteNaturalLanguageQuery() {
        runTest("P0: Natural Language: 'mute C2 level for System out' targets C2 send") {
            let uad = UADClient()
            let chs = TestAudioFixture.makeChannels(count: 4)
            chs[1]?.name = "System Out-ST"
            uad.channels = chs
            let auditor = AIAudioAuditor(uadClient: uad)
            let chat = AIChatEngine()

            guard let ch1 = uad.channels[1] else {
                assertTrue(false, "Channel 1 must exist")
                return
            }
            ch1.sends[3]?.bypass = false // C2 initial unmuted

            // Execute command
            var reply = ""
            chat.processQuery(query: "mute C2 level for System out", uad: uad, auditor: auditor) { rep in
                reply = rep
            }
            assertTrue(reply.contains("Muted C2 (HP 2)"), "Must confirm muting C2 send")
            assertTrue(ch1.sends[3]?.bypass ?? false, "C2 send bypass must be true (muted)")

            // Test Undo restores C2 send
            var replyUndo = ""
            chat.processQuery(query: "undo", uad: uad, auditor: auditor) { rep in
                replyUndo = rep
            }
            assertTrue(replyUndo.contains("Undid"), "Undo must succeed")
            assertFalse(ch1.sends[3]?.bypass ?? true, "C2 send bypass must be restored to false (unmuted)")
        }
    }

    /// Test Gemini API key unrestricted format support (Google AI Studio AIzaSy..., GCP/Vertex AQ...)
    public static func testGeminiApiKeyAnyFormatSupport() {
        runTest("P0: Gemini API key accepts all formats (AQ..., AIzaSy...) without restrictions") {
            let chat = AIChatEngine()

            // 1. Key starting with AQ.
            let testKeyAQ = "AQ.mock_sample_api_key_token_for_testing_purposes_only"
            chat.geminiApiKey = testKeyAQ
            assertEqual(chat.geminiApiKey, testKeyAQ, "Must accept key starting with 'AQ.' without restrictions")

            // 2. Test URLComponents query item and character safety
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(chat.geminiModel):generateContent")
            components?.queryItems = [
                URLQueryItem(name: "key", value: chat.geminiApiKey)
            ]
            assertTrue(components?.url != nil, "URLComponents must successfully build valid URL with AQ. key")
            let urlString = components?.url?.absoluteString ?? ""
            assertTrue(urlString.contains(testKeyAQ), "Built URL must preserve the entire AQ. key string")

            // 3. Test accessory view and pasteable text field input
            let accessory = ApiKeyDialogAccessoryView(currentKey: testKeyAQ)
            assertEqual(accessory.inputField.stringValue, testKeyAQ, "Accessory view inputField must hold AQ. key")
            accessory.clearButton.performClick(nil)
            assertEqual(accessory.inputField.stringValue, "", "Clear button must wipe text field")
        }
    }

    /// Test zero input / silent channel telemetry queries (0ms instant response without cloud timeout)
    public static func testZeroInputChannelsNaturalLanguageQuery() {
        runTest("P0: Telemetry Query: 'channels with zero input' detects silent tracks in 0ms") {
            let uad = UADClient()
            uad.channels = TestAudioFixture.makeChannels(count: 8)
            let auditor = AIAudioAuditor(uadClient: uad)
            let chat = AIChatEngine()

            // Channels 0, 1, 2 have active signal
            uad.channels[0]?.meterPeak = -12.5
            uad.channels[1]?.meterPeak = -18.2
            uad.channels[2]?.meterPeak = -6.0

            // Channels 3, 4, 5, 6, 7 have zero input / silent (<= -60 dBFS)
            uad.channels[3]?.meterPeak = -77.0
            uad.channels[4]?.meterPeak = -72.0
            uad.channels[5]?.meterPeak = -77.0
            uad.channels[6]?.meterPeak = -65.0
            uad.channels[7]?.meterPeak = -77.0

            // 1. Query: "channels with zero input"
            var reply1 = ""
            chat.processQuery(query: "channels with zero input", uad: uad, auditor: auditor) { rep in
                reply1 = rep
            }
            assertTrue(reply1.contains("Channels with Zero Input / Silent"), "Must detect silent tracks")
            assertTrue(reply1.contains("Ch 4"), "Must list Ch 4 as zero input")
            assertTrue(reply1.contains("Ch 5"), "Must list Ch 5 as zero input")
            assertTrue(reply1.contains("Active Signals (3)"), "Must list 3 active channels")

            // 2. Query variations: "which channels have no signal" / "silent channels"
            var reply2 = ""
            chat.processQuery(query: "which channels have no signal?", uad: uad, auditor: auditor) { rep in
                reply2 = rep
            }
            assertTrue(reply2.contains("Channels with Zero Input / Silent"), "Must match 'which channels have no signal?'")

            // 3. When all channels are active (> -60 dBFS)
            for ch in uad.channels.values {
                ch.meterPeak = -14.0
            }
            var replyAllActive = ""
            chat.processQuery(query: "channels with zero input", uad: uad, auditor: auditor) { rep in
                replyAllActive = rep
            }
            assertTrue(replyAllActive.contains("All 8 Apollo channels currently have active audio signals"), "Must report all active when none are silent")
        }
    }

    /// Test active audio signals, console summary, mute/solo, fader, and pan telemetry queries
    public static func testActiveSignalAndConsoleSummaryQueries() {
        runTest("P0: Telemetry Queries: 'channels with signal', 'console summary', faders, and mutes") {
            let uad = UADClient()
            uad.channels = TestAudioFixture.makeChannels(count: 8)
            let auditor = AIAudioAuditor(uadClient: uad)
            let chat = AIChatEngine()

            uad.channels[0]?.meterPeak = -8.5
            uad.channels[0]?.fader = 0.8
            uad.channels[0]?.faderDb = 0.0
            uad.channels[1]?.meterPeak = -16.0
            uad.channels[1]?.fader = 0.7
            uad.channels[1]?.faderDb = -3.5
            uad.channels[2]?.mute = true
            uad.channels[3]?.solo = true
            uad.channels[4]?.pan = -0.5 // L 50%

            // 1. "which channels have signal"
            var replyActive = ""
            chat.processQuery(query: "which channels have signal?", uad: uad, auditor: auditor) { rep in
                replyActive = rep
            }
            assertTrue(replyActive.contains("Channels Receiving Signal"), "Must report channels receiving signal")
            assertTrue(replyActive.contains("Ch 1"), "Must list Ch 1")
            assertTrue(replyActive.contains("Peak -8.5 dBFS"), "Must show peak level")

            // 1b. "analyze current incoming signals" (instant 0ms local telemetry)
            var replyIncoming = ""
            chat.processQuery(query: "analyze current incoming signals", uad: uad, auditor: auditor) { rep in
                replyIncoming = rep
            }
            assertTrue(replyIncoming.contains("Channels Receiving Signal"), "Must report channels receiving incoming signal")
            assertTrue(replyIncoming.contains("Ch 1"), "Must list Ch 1")

            // 2. "console summary"
            var replySummary = ""
            chat.processQuery(query: "console summary", uad: uad, auditor: auditor) { rep in
                replySummary = rep
            }
            assertTrue(replySummary.contains("Universal Audio Apollo Console Summary"), "Must produce console summary")
            assertTrue(replySummary.contains("8 total channels"), "Must report hardware layout")
            assertTrue(replySummary.contains("1 muted (Ch 3)"), "Must report muted track Ch 3")
            assertTrue(replySummary.contains("1 soloed (Ch 4)"), "Must report soloed track Ch 4")

            // 3. "which channels are muted?"
            var replyMuted = ""
            chat.processQuery(query: "which channels are muted?", uad: uad, auditor: auditor) { rep in
                replyMuted = rep
            }
            assertTrue(replyMuted.contains("Muted Channels (1)") && replyMuted.contains("Ch 3"), "Must report muted track Ch 3")

            // 4. "who is soloed?"
            var replySolo = ""
            chat.processQuery(query: "who is soloed?", uad: uad, auditor: auditor) { rep in
                replySolo = rep
            }
            assertTrue(replySolo.contains("Soloed Channels (1)") && replySolo.contains("Ch 4"), "Must report soloed track Ch 4")

            // 5. "fader levels"
            var replyFaders = ""
            chat.processQuery(query: "what are the fader levels?", uad: uad, auditor: auditor) { rep in
                replyFaders = rep
            }
            assertTrue(replyFaders.contains("Apollo Console Fader Levels"), "Must report fader levels")

            // 6. "show panned tracks"
            var replyPans = ""
            chat.processQuery(query: "show panned tracks", uad: uad, auditor: auditor) { rep in
                replyPans = rep
            }
            assertTrue(replyPans.contains("Panned Channels"), "Must report panned channels")
            assertTrue(replyPans.contains("L 50%"), "Must show L 50% pan")
        }
    }

    /// Test instant offline hardware guide queries for SSL UF8 and UAD Apollo console
    public static func testHardwareGuideAndGestureQueries() {
        runTest("P0: Hardware Guide: Instant offline answers for UF8 faders, sends, preamp, and FLIP") {
            let uad = UADClient()
            uad.channels = TestAudioFixture.makeChannels(count: 8)
            let auditor = AIAudioAuditor(uadClient: uad)
            let chat = AIChatEngine()

            // 1. Fader Unity & Reset
            var repUnity = ""
            chat.processQuery(query: "how to reset fader to unity?", uad: uad, auditor: auditor) { rep in
                repUnity = rep
            }
            assertTrue(repUnity.contains("0.0 dB Unity Gain Reset"), "Must explain unity gain reset")
            assertTrue(repUnity.contains("AUTO + SEL"), "Must cite AUTO + SEL combo")
            assertTrue(repUnity.contains("-oo dB Floor Snap"), "Must explain -oo dB floor snap")

            // 2. CUE & Sends Focus Mode
            var repSends = ""
            chat.processQuery(query: "how to use sends mode?", uad: uad, auditor: auditor) { rep in
                repSends = rep
            }
            assertTrue(repSends.contains("Channel CUE & Sends Focus Mode"), "Must explain CUE & Sends mode")
            assertTrue(repSends.contains("SEND"), "Must cite SEND button")
            assertTrue(repSends.contains("AUX 1 & AUX 2"), "Must explain Aux 1 & 2 layout")
            assertTrue(repSends.contains("CUE 1, CUE 2"), "Must explain Cue 1-4 headphone mixes")

            // 3. Preamp Focus Mode & +48V Safety
            var repPreamp = ""
            chat.processQuery(query: "how to control preamp?", uad: uad, auditor: auditor) { rep in
                repPreamp = rep
            }
            assertTrue(repPreamp.contains("Preamp Focus Mode"), "Must explain Preamp Focus mode")
            assertTrue(repPreamp.contains("CHANNEL"), "Must cite CHANNEL button")
            assertTrue(repPreamp.contains("+48V Phantom Power"), "Must explain +48V")
            assertTrue(repPreamp.contains("Safety Double-Tap Interlock"), "Must cite +48V double-tap safety interlock")

            // 4. Plug-in Inspector
            var repPlugin = ""
            chat.processQuery(query: "how to tweak plugins?", uad: uad, auditor: auditor) { rep in
                repPlugin = rep
            }
            assertTrue(repPlugin.contains("Plug-in & Insert Inspector"), "Must explain plugin inspector")
            assertTrue(repPlugin.contains("PLUG-IN"), "Must cite PLUG-IN button")
            assertTrue(repPlugin.contains("Strip 1 (Master Power & Bypass)"), "Must explain Strip 1 power on/off")

            // 5. FLIP Button & Home Snap
            var repFlip = ""
            chat.processQuery(query: "what does flip do?", uad: uad, auditor: auditor) { rep in
                repFlip = rep
            }
            assertTrue(repFlip.contains("Global `FLIP` Button Operation"), "Must explain FLIP button")
            assertTrue(repFlip.contains("Single-Tap FLIP"), "Must explain single-tap")
            assertTrue(repFlip.contains("Double-Tap FLIP"), "Must explain double-tap home snap")

            // 6. Monitor Volume & Emergency Mute
            var repMon = ""
            chat.processQuery(query: "how does monitor mute work?", uad: uad, auditor: auditor) { rep in
                repMon = rep
            }
            assertTrue(repMon.contains("Center Circle Key"), "Must cite Center Circle key")
            assertTrue(repMon.contains("Note 100"), "Must cite Note 100")
            assertTrue(repMon.contains("Hearing Safety Guarantee"), "Must cite hearing safety guarantee")

            // 7. SSL 360 Setup
            var repSetup = ""
            chat.processQuery(query: "how to setup ssl 360?", uad: uad, auditor: auditor) { rep in
                repSetup = rep
            }
            assertTrue(repSetup.contains("SSL 360° Software & Hardware Configuration"), "Must explain SSL 360 setup")
            assertTrue(repSetup.contains("Layer 3"), "Must cite Layer 3")
            assertTrue(repSetup.contains("Port 9"), "Must cite Port 9")

            // 8. General Guide / Help
            var repHelp = ""
            chat.processQuery(query: "uf8 guide", uad: uad, auditor: auditor) { rep in
                repHelp = rep
            }
            assertTrue(repHelp.contains("SSL UF8 & Universal Audio Apollo Hardware Reference Guide"), "Must produce full hardware reference guide")
            assertTrue(repHelp.contains("CHANNEL"), "Must list CHANNEL")
            assertTrue(repHelp.contains("SEND"), "Must list SEND")
        }
    }

    /// Test complete channel inventory queries (e.g. "Full list pls", "all channels") without cut-off
    public static func testFullChannelListInventoryQuery() {
        runTest("P0: Channel Inventory: 'Full list pls' returns all channels organized by UF8 banks without cut-off") {
            let uad = UADClient()
            uad.channels = TestAudioFixture.makeChannels(count: 16)
            let auditor = AIAudioAuditor(uadClient: uad)
            let chat = AIChatEngine()

            uad.channels[0]?.name = "Lead Vocal"
            uad.channels[0]?.fader = 0.8
            uad.channels[0]?.faderDb = 0.0
            uad.channels[0]?.meterPeak = -8.5

            uad.channels[7]?.name = "OctoPre 1"
            uad.channels[8]?.name = "OctoPre 2"

            uad.channels[15]?.name = "Aux 2"
            uad.channels[15]?.chType = "aux"

            // 1. "Full list pls" (User's exact prompt from screenshot)
            var replyFull = ""
            chat.processQuery(query: "Full list pls", uad: uad, auditor: auditor) { rep in
                replyFull = rep
            }
            assertTrue(replyFull.contains("Universal Audio Apollo Full Channel Inventory (16 Tracks)"), "Must produce full inventory title")
            assertTrue(replyFull.contains("Bank 1 (UF8 Physical Faders 1–8"), "Must show Bank 1 header")
            assertTrue(replyFull.contains("Bank 2 (UF8 Physical Faders 1–8"), "Must show Bank 2 header")
            assertTrue(replyFull.contains("Lead Vocal"), "Must contain Lead Vocal")
            assertTrue(replyFull.contains("OctoPre 1"), "Must contain OctoPre 1")
            assertTrue(replyFull.contains("OctoPre 2"), "Must contain OctoPre 2 beyond channel 8 without cut-off")
            assertTrue(replyFull.contains("Track 16"), "Must contain Track 16 to ensure full completion")

            // 2. Query variations
            var replyAll = ""
            chat.processQuery(query: "all channels", uad: uad, auditor: auditor) { rep in
                replyAll = rep
            }
            assertTrue(replyAll.contains("Universal Audio Apollo Full Channel Inventory"), "Must match 'all channels'")
        }
    }

    /// Test cancellation of running execution via AIChatEngine and AIChatWindowController
    public static func testQueryCancellationAndStopExecution() {
        runTest("P0: Execution Cancellation: cancelCurrentQuery aborts tasks & restores UI ready state") {
            let chat = AIChatEngine()

            // 1. Initial state
            assertFalse(chat.isQueryCancelled, "isQueryCancelled must initially be false")

            // 2. Trigger cancellation
            chat.cancelCurrentQuery()
            assertTrue(chat.isQueryCancelled, "isQueryCancelled must be true after cancelCurrentQuery")

            // 3. New query resets cancellation flag
            let uad = UADClient()
            uad.channels = TestAudioFixture.makeChannels(count: 4)
            let auditor = AIAudioAuditor(uadClient: uad)

            var reply = ""
            chat.processQuery(query: "Console summary", uad: uad, auditor: auditor) { rep in
                reply = rep
            }
            assertFalse(chat.isQueryCancelled, "processQuery must reset isQueryCancelled to false")
            assertTrue(reply.contains("Universal Audio Apollo Console Summary"), "Console summary should succeed")

            // 4. Test AIChatWindowController cancellation state
            let controller = AIChatWindowController(uad: uad, auditor: auditor)
            assertFalse(controller.isExecuting, "Controller should not be executing initially")

            controller.cancelExecution()
            assertFalse(controller.isExecuting, "Controller isExecuting must be false after cancelExecution")
        }
    }

    /// Test Prompt Suggestions card and chips structure
    public static func testPromptSuggestionsCardAndChips() {
        runTest("P0: Prompt Suggestions: Card container & chips provide 1-click access to core commands") {
            // 1. Test PromptChipButton
            let chip = PromptChipButton(title: "📋 Full list pls", prompt: "Full list pls")
            assertEqual(chip.promptValue, "Full list pls", "PromptChipButton must preserve exact prompt")
            assertEqual(chip.title, "📋 Full list pls", "PromptChipButton must display assigned title")
            assertTrue(chip.isFlipped, "PromptChipButton must be flipped for top-down layout")

            // 2. Test HeroCardButton flipped status
            let heroBtn = HeroCardButton(
                frame: NSRect(x: 0, y: 0, width: 280, height: 78),
                icon: "⚡",
                title: "Overloaded Tracks",
                subtitle: "Scan all 32 channels for converter clipping"
            )
            assertTrue(heroBtn.isFlipped, "HeroCardButton must be flipped for top-down layout")
            assertEqual(heroBtn.titleLabel.stringValue, "Overloaded Tracks", "HeroCardButton title must match")
        }
    }

    /// Test Timed Listening Intent Parsing across natural prompt variations
    public static func testTimedListeningIntentParsing() {
        runTest("P0: Timed Listening: parseTimedListeningIntent extracts duration and subquery accurately") {
            // 1. "listening 10 secs and analyze xyz..."
            let intent1 = AIChatEngine.parseTimedListeningIntent("listening 10 secs and analyze xyz...")
            assertTrue(intent1 != nil, "Must recognize 'listening 10 secs and analyze xyz...'")
            assertEqual(intent1?.seconds ?? 0, 10.0, "Duration must be 10.0 seconds")
            assertEqual(intent1?.subQuery ?? "", "analyze xyz...", "Subquery must extract 'analyze xyz...'")

            // 2. "listen 10 seconds and analyze incoming signals"
            let intent2 = AIChatEngine.parseTimedListeningIntent("listen 10 seconds and analyze incoming signals")
            assertTrue(intent2 != nil, "Must recognize 'listen 10 seconds and analyze incoming signals'")
            assertEqual(intent2?.seconds ?? 0, 10.0, "Duration must be 10.0 seconds")
            assertEqual(intent2?.subQuery ?? "", "analyze incoming signals", "Subquery must extract 'analyze incoming signals'")

            // 3. "listen for 5 secs and summarize"
            let intent3 = AIChatEngine.parseTimedListeningIntent("listen for 5 secs and summarize")
            assertTrue(intent3 != nil, "Must recognize 'listen for 5 secs and summarize'")
            assertEqual(intent3?.seconds ?? 0, 5.0, "Duration must be 5.0 seconds")
            assertEqual(intent3?.subQuery ?? "", "summarize", "Subquery must extract 'summarize'")

            // 4. "listening 10s and analyze headroom"
            let intent4 = AIChatEngine.parseTimedListeningIntent("listening 10s and analyze headroom")
            assertTrue(intent4 != nil, "Must recognize 'listening 10s and analyze headroom'")
            assertEqual(intent4?.seconds ?? 0, 10.0, "Duration must be 10.0 seconds")
            assertEqual(intent4?.subQuery ?? "", "analyze headroom", "Subquery must extract 'analyze headroom'")

            // 5. "listen and analyze" (default to 10.0s)
            let intent5 = AIChatEngine.parseTimedListeningIntent("listen and analyze")
            assertTrue(intent5 != nil, "Must recognize 'listen and analyze'")
            assertEqual(intent5?.seconds ?? 0, 10.0, "Default duration must be 10.0 seconds")

            // 6. Non-matching queries must return nil
            assertFalse(AIChatEngine.parseTimedListeningIntent("tell me channels in Overloaded") != nil, "Overload query must not trigger timed listening")
            assertFalse(AIChatEngine.parseTimedListeningIntent("which channels have zero input?") != nil, "Zero input query must not trigger timed listening")
            assertFalse(AIChatEngine.parseTimedListeningIntent("set -infinite dB for all channels") != nil, "Set infinity query must not trigger timed listening")
        }
    }

    /// Test Timed Listening Execution, Data Points Recording, File Saving, and Acoustic Summary
    public static func testTimedListeningExecutionDataPointsAndSummary() {
        runTest("P0: Timed Listening: executes timed capture, saves data points report, and returns summary") {
            let uad = UADClient()
            uad.channels = TestAudioFixture.makeChannels(count: 8)

            // Configure channel states: Ch 1 active, Ch 2 hot, Ch 3..8 silent
            uad.channels[0]?.name = "Kick"
            uad.channels[0]?.meterPeak = -6.2
            uad.channels[0]?.meterLevel = -12.0
            uad.channels[0]?.faderDb = -2.0

            uad.channels[1]?.name = "SD-Bottom"
            uad.channels[1]?.meterPeak = -2.1
            uad.channels[1]?.meterLevel = -7.5
            uad.channels[1]?.faderDb = -4.0

            for i in 2..<8 {
                uad.channels[i]?.meterPeak = -144.0
                uad.channels[i]?.meterLevel = -144.0
                uad.channels[i]?.faderDb = -144.0
            }

            let auditor = AIAudioAuditor(uadClient: uad)
            let chat = AIChatEngine()
            chat.aiProvider = "auto"

            let intent = AIChatEngine.TimedListeningIntent(seconds: 0.05, subQuery: "analyze incoming signals")
            var progressUpdates: [String] = []
            var finalSummary = ""

            let exp = DispatchSemaphore(value: 0)

            chat.handleTimedListeningQuery(
                intent: intent,
                rawQuery: "listening 10 secs and analyze incoming signals",
                uad: uad,
                auditor: auditor,
                sampleInterval: 0.01,
                progress: { prog in
                    progressUpdates.append(prog)
                },
                completion: { rep in
                    finalSummary = rep
                    exp.signal()
                }
            )

            let waitResult = exp.wait(timeout: .now() + 2.0)
            assertEqual(waitResult, .success, "Timed listening query must finish within timeout")

            // 1. Verify summary content
            assertTrue(finalSummary.contains("Mixer Telemetry Capture & Analysis"), "Summary must include header")
            assertTrue(finalSummary.contains("Session Acoustic Summary"), "Summary must include acoustic overview")
            assertTrue(finalSummary.contains("Active Channels:"), "Summary must detail active channels count")
            assertTrue(finalSummary.contains("Kick"), "Summary must report active Kick track")
            assertTrue(finalSummary.contains("SD-Bottom"), "Summary must report active SD-Bottom track")
            assertTrue(finalSummary.contains("Saved session report:"), "Summary must reference saved report file")

            // 2. Verify file was saved to disk
            let activeUrl = AIReportManager.shared.activeReportURL
            assertTrue(activeUrl != nil, "AIReportManager activeReportURL must be populated")
            if let fileUrl = activeUrl {
                assertTrue(FileManager.default.fileExists(atPath: fileUrl.path), "Saved telemetry file must exist on disk")
                let content = (try? String(contentsOf: fileUrl)) ?? ""
                assertTrue(content.contains("UA-MCU BRIDGE - AI STUDIO CO-PRODUCER TELEMETRY CAPTURE"), "File must contain telemetry header")
                assertTrue(content.contains("MONITORED CHANNEL DATA POINTS"), "File must contain data points matrix")
                assertTrue(content.contains("Kick"), "File must list Kick data point")
                assertTrue(content.contains("SD-Bottom"), "File must list SD-Bottom data point")
            }

            // 3. Test execution cancellation
            let cancelExp = DispatchSemaphore(value: 0)
            var cancelReply = ""
            chat.handleTimedListeningQuery(
                intent: AIChatEngine.TimedListeningIntent(seconds: 5.0, subQuery: "test cancel"),
                rawQuery: "listen 5s and test cancel",
                uad: uad,
                auditor: auditor,
                sampleInterval: 0.01,
                progress: nil,
                completion: { rep in
                    cancelReply = rep
                    cancelExp.signal()
                }
            )

            // Cancel immediately
            chat.cancelCurrentQuery()
            let cancelWait = cancelExp.wait(timeout: .now() + 1.0)
            assertEqual(cancelWait, .success, "Cancelled query must return within timeout")
            assertTrue(cancelReply.contains("cancelled"), "Cancelled query must return cancellation message")
        }
    }

    /// Test Direct Local Control Commands (Mute, Solo, Faders, Pan, Preamp, Monitor, Banking, Modes)
    public static func testDirectTactileAndUADConsoleControlCommands() {
        runTest("P0: Direct Local Controls: Chatbot controls mutes, solos, faders, pans, preamps, monitor, and banking locally without Gemini API") {
            let (mcu, uad, _) = TestAudioFixture.makeMCUEngine(channelCount: 8)
            uad.channels[0]?.name = "Kick"
            uad.channels[1]?.name = "Vocal"
            uad.channels[1]?.preamp.hasPreamp = true
            uad.channels[1]?.preamp.gain = 20.0
            uad.channels[1]?.preamp.lowCut = false
            uad.channels[1]?.preamp.pad = false
            uad.channels[1]?.preamp.phase = false
            uad.channels[1]?.preamp.phantom48V = false

            let chat = AIChatEngine()

            // 1. Single-track Mute & Unmute
            var reply = ""
            chat.processQuery(query: "mute track 1", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.channels[0]?.mute == true, "Track 1 must be muted")
            assertTrue(reply.contains("Muted"), "Reply must confirm mute: \(reply)")

            chat.processQuery(query: "unmute kick", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.channels[0]?.mute == false, "Kick must be unmuted")
            assertTrue(reply.contains("Unmuted"), "Reply must confirm unmute: \(reply)")

            // 2. Single-track Solo & Unsolo
            chat.processQuery(query: "solo vocal", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.channels[1]?.solo == true, "Vocal must be soloed")
            assertTrue(reply.contains("Soloed"), "Reply must confirm solo: \(reply)")

            chat.processQuery(query: "unsolo track 2", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.channels[1]?.solo == false, "Vocal must be unsoloed")
            assertTrue(reply.contains("Unsoloed"), "Reply must confirm unsolo: \(reply)")

            // 3. Global Mute & Solo
            chat.processQuery(query: "mute all", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.channels.values.allSatisfy { $0.mute }, "All channels must be muted")

            chat.processQuery(query: "unmute all", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.channels.values.allSatisfy { !$0.mute }, "All channels must be unmuted")

            chat.processQuery(query: "clear all solos", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.channels.values.allSatisfy { !$0.solo }, "All channels must be unsoloed")

            // 4. Fader Levels
            chat.processQuery(query: "set track 1 to 0 dB", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertEqual(uad.channels[0]?.faderDb ?? -999, 0.0, "Track 1 must be set to 0.0 dB unity")
            assertTrue(reply.contains("0.0 dB"), "Reply must confirm 0.0 dB")

            chat.processQuery(query: "fader vocal to -6 dB", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(abs((uad.channels[1]?.faderDb ?? -999) - (-6.0)) < 0.05, "Vocal must be set to -6.0 dB")

            chat.processQuery(query: "pull down track 1", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertEqual(uad.channels[0]?.faderDb ?? -999, -144.0, "Track 1 fader must be pulled down to -144 dB")

            chat.processQuery(query: "unity all faders", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.channels.values.allSatisfy { abs($0.faderDb) < 0.1 }, "All faders must be reset to unity")

            // 5. Pan Control
            chat.processQuery(query: "pan track 1 left 40", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertEqual(uad.channels[0]?.pan ?? -999, -0.40, "Track 1 pan must be left 40 (-0.40)")

            chat.processQuery(query: "pan vocal center", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertEqual(uad.channels[1]?.pan ?? -999, 0.0, "Vocal pan must be centered (0.0)")

            chat.processQuery(query: "center all pans", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.channels.values.allSatisfy { $0.pan == 0.0 }, "All pans must be centered")

            // 6. Preamp Focus Controls (48V, Low Cut, Pad, Phase, Gain)
            chat.processQuery(query: "turn on 48V on track 2", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.channels[1]?.preamp.phantom48V == true, "Vocal 48V must be engaged")

            chat.processQuery(query: "48V off on vocal", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.channels[1]?.preamp.phantom48V == false, "Vocal 48V must be disengaged")

            chat.processQuery(query: "enable low cut on track 2", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.channels[1]?.preamp.lowCut == true, "Vocal low-cut must be enabled")

            chat.processQuery(query: "engage pad on vocal", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.channels[1]?.preamp.pad == true, "Vocal pad must be engaged")

            chat.processQuery(query: "invert phase on track 2", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.channels[1]?.preamp.phase == true, "Vocal phase must be inverted")

            chat.processQuery(query: "set preamp gain vocal to 35 dB", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertEqual(uad.channels[1]?.preamp.gain ?? 0, 35.0, "Vocal preamp gain must be set to +35.0 dB")

            // 7. Master Monitor Volume & Mute
            chat.processQuery(query: "mute monitor", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(uad.monitorMute, "Master Monitor must be muted")

            chat.processQuery(query: "unmute monitor", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertFalse(uad.monitorMute, "Master Monitor must be unmuted")

            chat.processQuery(query: "set monitor volume to -18 dB", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertEqual(uad.monitorLevelDb, -18.0, "Master Monitor volume must be set to -18.0 dB")

            chat.processQuery(query: "turn up monitor 2 dB", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertEqual(uad.monitorLevelDb, -16.0, "Master Monitor volume must be nudged up to -16.0 dB")

            // 8. Surface Modes & Navigation
            chat.processQuery(query: "bank 2", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertEqual(mcu.bankOffset, 8, "Bank offset must be set to 8 (Bank 2)")

            chat.processQuery(query: "bank 1", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertEqual(mcu.bankOffset, 0, "Bank offset must be set to 0 (Bank 1)")

            chat.processQuery(query: "enter sends mode", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(mcu.sendsFocusMode, "Sends focus mode must be active")

            chat.processQuery(query: "exit sends mode", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertFalse(mcu.sendsFocusMode, "Sends focus mode must be inactive")

            chat.processQuery(query: "rough mix", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(reply.contains("Auto-Rough Mix"), "Rough mix must execute and confirm")

            // 9. UAD REC / UAD MON
            chat.processQuery(query: "set track 2 to UAD REC", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(reply.contains("UAD REC"), "Reply must confirm UAD REC")

            chat.processQuery(query: "set track 2 to UAD MON", uad: uad, auditor: mcu.auditor) { reply = $0 }
            assertTrue(reply.contains("UAD MON"), "Reply must confirm UAD MON")
        }
    }

    /// Test User Prompt Bubble Zero-Clipping, NSTextView Rich Formatting & Responsive Sizing
    public static func testUserPromptBubbleZeroClippingAndRichFormatting() {
        runTest("P0: User Prompt Bubble: Rich NSTextView layout with zero clipping and minimum width") {
            let (mcu, uad, _) = TestAudioFixture.makeMCUEngine(channelCount: 8)
            let controller = AIChatWindowController(uad: uad, auditor: mcu.auditor)

            // 1. Short prompt
            let shortMsg = AIChatWindowController.ChatMessage(sender: .user, text: "mute kick", timestamp: Date())
            let shortBubble = controller.createUserBubble(msg: shortMsg, canvasWidth: 700, startY: 20)

            assertTrue(shortBubble.bounds.width >= 110.0, "Short bubble must meet minimum width of 110pt to prevent truncation")
            assertTrue(shortBubble.bounds.height > 30.0, "Short bubble height must include header and padded capsule")
            assertEqual(shortBubble.subviews.count, 2, "Bubble container must contain header label and capsule view")

            guard let shortCapsule = shortBubble.subviews.last as? FlippedCanvasView,
                  let shortTextView = shortCapsule.subviews.first as? NSTextView else {
                assertTrue(false, "Short bubble must embed NSTextView inside capsule")
                return
            }
            assertEqual(shortTextView.string, "mute kick", "TextView string must match short prompt")
            assertTrue(shortTextView.isSelectable, "TextView must be selectable for copy/paste")
            assertFalse(shortTextView.isEditable, "TextView must not be editable")

            // 2. Long multi-line prompt
            let longText = "listening 10 secs and analyze incoming signals across all 32 channels and tell me which tracks are clipping or silent"
            let longMsg = AIChatWindowController.ChatMessage(sender: .user, text: longText, timestamp: Date())
            let longBubble = controller.createUserBubble(msg: longMsg, canvasWidth: 700, startY: 100)

            assertTrue(longBubble.bounds.width > 200.0, "Long bubble width must scale with content")
            assertTrue(longBubble.bounds.height > shortBubble.bounds.height, "Multi-line bubble must expand vertically without clipping")

            // 3. Prompt Options Bar Verification (Relative Timestamp, Rerun, Edit, Copy)
            guard let optionsRow = shortBubble.subviews.first as? FlippedCanvasView else {
                assertTrue(false, "Short bubble subviews[0] must be optionsRow FlippedCanvasView")
                return
            }
            let optionButtons = optionsRow.subviews.compactMap { $0 as? NSButton }
            assertEqual(optionButtons.count, 3, "Options row must contain exactly 3 action buttons (Rerun, Edit, Copy)")

            let timeLabels = optionsRow.subviews.compactMap { $0 as? NSTextField }
            assertEqual(timeLabels.count, 1, "Options row must contain 1 relative time label")
            assertEqual(timeLabels.first?.stringValue, "Just now", "Recent prompt timestamp must format to 'Just now'")

            // Verify Relative Time Formatter
            assertEqual(AIChatWindowController.formatRelativeTime(from: Date().addingTimeInterval(-28800)), "8 hours ago", "8 hours ago relative timestamp must match user reference exactly")
            assertEqual(AIChatWindowController.formatRelativeTime(from: Date().addingTimeInterval(-3600)), "1 hour ago", "1 hour ago relative timestamp formatting")
            assertEqual(AIChatWindowController.formatRelativeTime(from: Date().addingTimeInterval(-300)), "5m ago", "Minutes ago relative timestamp formatting")

            // Test Copy Prompt Action
            if let copyBtn = optionButtons.first(where: { $0.action == #selector(AIChatWindowController.handleCopyPrompt(_:)) }) {
                controller.handleCopyPrompt(copyBtn)
                let clipText = NSPasteboard.general.string(forType: .string)
                assertEqual(clipText, "mute kick", "Copy prompt button must copy prompt text to pasteboard")
            } else {
                assertTrue(false, "Copy prompt button must be present")
            }

            // Test Edit Prompt Action
            if let editBtn = optionButtons.first(where: { $0.action == #selector(AIChatWindowController.handleEditPrompt(_:)) }) {
                controller.inputField.stringValue = ""
                controller.handleEditPrompt(editBtn)
                assertEqual(controller.inputField.stringValue, "mute kick", "Edit prompt button must populate inputField with prompt text")
            } else {
                assertTrue(false, "Edit prompt button must be present")
            }
        }
    }

    /// Test Gemini Response Card: Icon-Only Copy Button & More Menu (Export to Docs, Draft in Gmail, About)
    public static func testGeminiCardIconOnlyCopyAndMoreMenu() {
        runTest("P0: Gemini Card: Icon-only Copy button & More menu popup with Docs, Gmail, About") {
            let (mcu, uad, _) = TestAudioFixture.makeMCUEngine(channelCount: 8)
            let controller = AIChatWindowController(uad: uad, auditor: mcu.auditor)

            let sampleResponse = "Universal Audio Apollo mixer is running with 6 dB clean master headroom."
            let msg = AIChatWindowController.ChatMessage(sender: .gemini, text: sampleResponse, timestamp: Date())
            let card = controller.createGeminiCard(msg: msg, canvasWidth: 700, startY: 20)

            assertTrue(card.bounds.height > 60.0, "Card height must accommodate body and action row")

            // Find all NSButtons in card subviews
            let buttons = card.subviews.compactMap { $0 as? NSButton }
            assertTrue(buttons.count >= 5, "Card must include at least 5 action buttons (Copy, Share, Thumbs Up, Thumbs Down, More)")

            // 1. First button is the Copy button (icon only, title empty or ❐, NOT containing 'Copy')
            let copyBtn = buttons[0]
            assertEqual(copyBtn.identifier?.rawValue, sampleResponse, "Copy button identifier must store response text payload")
            assertFalse(copyBtn.title.contains("Copy"), "Copy button MUST NOT contain the text 'Copy'")
            assertTrue(copyBtn.toolTip == "Copy response", "Copy button tooltip must guide user")

            // 2. More button is the 5th button
            let moreBtn = buttons[4]
            assertTrue(moreBtn.toolTip == "More actions" || moreBtn.toolTip == "More options", "More button must have proper tooltip")
            assertEqual(moreBtn.identifier?.rawValue, sampleResponse, "More button identifier must store response text payload")

            // 3. Zero Unnecessary Gap: Verify action row sits snuggly below textView with zero dead gap
            if let tv = card.subviews.compactMap({ $0 as? NSTextView }).first {
                let distance = copyBtn.frame.minY - tv.frame.maxY
                assertTrue(distance <= 12.0, "Action row must sit snuggly below textView (distance: \(distance) <= 12)")
                assertTrue(card.frame.height <= tv.frame.maxY + 40.0, "Card height must have zero excess padding")
            }

            // 4. Zero Gap on Multi-Bank Channel Inventory Response (33 tracks)
            let multiBankResponse = """
            🎛️ **Universal Audio Apollo Full Channel Inventory (33 Tracks)**:
            Complete mixer mapping across SSL UF8 physical 8-fader banking layers:

            ### ── Bank 5 (UF8 Physical Faders 1–8 • Tracks 33–33) ──
            • **Track 33**: `AUX 2` (Aux) | Fader: -oo dB | Pan: C | Peak: -oo dBFS (Silent)

            💡 *Tip: Use `< PAGE >` on your UF8 to jump between Bank 1, Bank 2, Bank 3, etc.*
            """
            let multiMsg = AIChatWindowController.ChatMessage(sender: .gemini, text: multiBankResponse, timestamp: Date())
            let multiCard = controller.createGeminiCard(msg: multiMsg, canvasWidth: 680, startY: 20)
            if let tv = multiCard.subviews.compactMap({ $0 as? NSTextView }).first,
               let btn = multiCard.subviews.compactMap({ $0 as? NSButton }).first {
                let distance = btn.frame.minY - tv.frame.maxY
                assertTrue(distance <= 12.0, "Action row must sit snuggly below multi-bank textView (distance: \(distance) <= 12)")
                assertTrue(multiCard.frame.height <= tv.frame.maxY + 40.0, "Multi-bank card must have zero dead vertical gap")
            }
        }
    }

    /// Test local CUE and Sends information inspection and tactile control (0ms, offline, zero Gemini API)
    public static func testLocalCueInformationAndControl() {
        runTest("P0: Local CUE & Sends: 0ms offline inspection of CUE matrix, per-channel sends, bus feeds, and gain control") {
            let (mcu, uad, _) = TestAudioFixture.makeMCUEngine(channelCount: 8)
            guard let auditor = mcu.auditor else {
                assertTrue(false, "mcu.auditor must not be nil")
                return
            }
            let chat = AIChatEngine()

            // Setup channels
            guard let ch0 = uad.channels[0], let ch1 = uad.channels[1] else {
                assertTrue(false, "Channels 0 and 1 must exist")
                return
            }
            ch0.name = "Lead Vox"
            ch1.name = "Acoustic Gtr"

            // Setup CUE sends: ch0 -> CUE 1 (HP 1, sendIdx 2) @ 0.0 dB
            ch0.sends[2]?.gainDb = 0.0
            ch0.sends[2]?.gain = UADCurve.dbToTapered(0.0)
            ch0.sends[2]?.pan = 0.0
            ch0.sends[2]?.bypass = false

            // ch1 -> CUE 1 (sendIdx 2) @ -6.0 dB, Pan L30
            ch1.sends[2]?.gainDb = -6.0
            ch1.sends[2]?.gain = UADCurve.dbToTapered(-6.0)
            ch1.sends[2]?.pan = -0.3
            ch1.sends[2]?.bypass = false

            // ch1 -> CUE 2 (HP 2, sendIdx 3) @ -12.0 dB, Muted
            ch1.sends[3]?.gainDb = -12.0
            ch1.sends[3]?.gain = UADCurve.dbToTapered(-12.0)
            ch1.sends[3]?.bypass = true

            // 1. "show cue sends" (global CUE & sends matrix)
            var repMatrix = ""
            chat.processQuery(query: "show cue sends", uad: uad, auditor: auditor) { rep in
                repMatrix = rep
            }
            assertTrue(repMatrix.contains("Apollo CUE & SENDS Matrix"), "Must produce CUE matrix")
            assertTrue(repMatrix.contains("CUE 1 / HP 1"), "Must display CUE 1 / HP 1 bus")
            assertTrue(repMatrix.contains("Lead Vox"), "Must display active Lead Vox send")
            assertTrue(repMatrix.contains("Acoustic Gtr"), "Must display active Acoustic Gtr send")
            assertTrue(repMatrix.contains("SEND"), "Must provide SSL UF8 hardware instructions")

            // 2. "cue sends for Lead Vox" (track-specific 8-strip send inspection)
            var repTrackSends = ""
            chat.processQuery(query: "cue sends for Lead Vox", uad: uad, auditor: auditor) { rep in
                repTrackSends = rep
            }
            assertTrue(repTrackSends.contains("CUE & SENDS Matrix for Track 1 (Lead Vox)"), "Must produce track-specific send matrix")
            assertTrue(repTrackSends.contains("Slot 3 (CUE 1)"), "Must list Slot 3 (CUE 1)")
            assertTrue(repTrackSends.contains("0.0 dB"), "Must show 0.0 dB level")
            assertTrue(repTrackSends.contains("Slot 7 (Track Output)"), "Must include Slot 7 output")
            assertTrue(repTrackSends.contains("Slot 8 (Track Pan)"), "Must include Slot 8 pan")

            // 3. "show cue 1" (specific CUE bus feeding tracks)
            var repBus = ""
            chat.processQuery(query: "show cue 1", uad: uad, auditor: auditor) { rep in
                repBus = rep
            }
            assertTrue(repBus.contains("C1 (HP 1)") || repBus.contains("CUE 1"), "Must report CUE 1 bus feeds")
            assertTrue(repBus.contains("Lead Vox") && repBus.contains("0.0 dB"), "Must list Lead Vox @ 0.0 dB")
            assertTrue(repBus.contains("Acoustic Gtr") && repBus.contains("-6.0 dB"), "Must list Acoustic Gtr @ -6.0 dB")
            assertTrue(repBus.contains("Bus Summary"), "Must report bus summary")

            // 4. "set cue 1 on track 1 to -3 dB" (direct CUE gain control)
            var repSetLevel = ""
            chat.processQuery(query: "set cue 1 on track 1 to -3 dB", uad: uad, auditor: auditor) { rep in
                repSetLevel = rep
            }
            assertTrue(repSetLevel.contains("Set") && repSetLevel.contains("-3.0 dB"), "Must confirm send level change")
            let actualDb = ch0.sends[2]?.gainDb ?? -999.0
            assertTrue(abs(actualDb - (-3.0)) < 0.5, "Track 1 Cue 1 gainDb must be approx -3.0 dB (got \(actualDb))")

            // 5. "mute C1 on Lead Vox"
            var repMute = ""
            chat.processQuery(query: "mute C1 on Lead Vox", uad: uad, auditor: auditor) { rep in
                repMute = rep
            }
            assertTrue(repMute.contains("Muted C1 (HP 1)"), "Must confirm send mute")
            assertTrue(ch0.sends[2]?.bypass == true, "C1 send bypass must be true")
        }
    }

    /// Test local UAD Plugins and Inserts information inspection and control (0ms, offline, zero Gemini API)
    public static func testLocalPluginInformationAndControl() {
        runTest("P0: Local Plugins & Inserts: 0ms offline inspection of DSP inventory, Unison models, per-track inserts, and bypass control") {
            let (mcu, uad, _) = TestAudioFixture.makeMCUEngine(channelCount: 8)
            guard let auditor = mcu.auditor else {
                assertTrue(false, "mcu.auditor must not be nil")
                return
            }
            let chat = AIChatEngine()

            // 1. Clean session (no plugins inserted)
            var repClean = ""
            chat.processQuery(query: "show plugins", uad: uad, auditor: auditor) { rep in
                repClean = rep
            }
            assertTrue(repClean.contains("Apollo Plug-in & Inserts Status"), "Must produce plugin status")
            assertTrue(repClean.contains("No plug-ins or Unison models are currently inserted"), "Must report clean session")
            assertTrue(repClean.contains("PLUG-IN"), "Must provide SSL UF8 PLUG-IN button guide")

            // Setup plugins on Channel 0 (Preamp channel)
            guard let ch0 = uad.channels[0], let ch1 = uad.channels[1] else {
                assertTrue(false, "Channels 0 and 1 must exist")
                return
            }
            ch0.name = "Lead Vox"
            ch0.recordPreEffects = false // UAD REC (Printed)
            ch0.unisonEffect.name = "UA 610-A"
            ch0.unisonEffect.power = true
            ch0.preamp.unisonPluginName = "UA 610-A"
            ch0.preamp.unisonPower = true

            // Insert 1: Teletronix LA-2A Gray (power on)
            let eff0 = UADEffect(index: 0, isUnison: false)
            eff0.name = "Teletronix LA-2A Gray"
            eff0.power = true
            eff0.parameters[0] = UADEffectParam(index: 0, name: "Peak Reduction", strVal: "45.0%", normVal: 0.45)
            eff0.parameters[1] = UADEffectParam(index: 1, name: "Gain", strVal: "+12.0 dB", normVal: 0.6)
            ch0.effects[0] = eff0

            // Insert 2: Precision EQ (power false / bypassed)
            let eff1 = UADEffect(index: 1, isUnison: false)
            eff1.name = "Precision EQ"
            eff1.power = false
            ch0.effects[1] = eff1

            // Setup Channel 1: Insert 1: UA 1176LN Rev E
            ch1.name = "Snare Top"
            ch1.recordPreEffects = true // UAD MON (Monitor only)
            let effSnare = UADEffect(index: 0, isUnison: false)
            effSnare.name = "UA 1176LN Rev E"
            effSnare.power = true
            effSnare.parameters[0] = UADEffectParam(index: 0, name: "Attack", strVal: "3", normVal: 0.3)
            effSnare.parameters[1] = UADEffectParam(index: 1, name: "Release", strVal: "5", normVal: 0.5)
            effSnare.parameters[2] = UADEffectParam(index: 2, name: "Ratio", strVal: "4:1", normVal: 0.0)
            ch1.effects[0] = effSnare

            // 2. "show plugins" with loaded plugins
            var repLoaded = ""
            chat.processQuery(query: "show plugins", uad: uad, auditor: auditor) { rep in
                repLoaded = rep
            }
            assertTrue(repLoaded.contains("UAD Plug-ins & Inserts Inventory"), "Must produce inventory")
            assertTrue(repLoaded.contains("Lead Vox") && repLoaded.contains("UA 610-A"), "Must list Lead Vox Unison plugin")
            assertTrue(repLoaded.contains("Teletronix LA-2A Gray"), "Must list LA-2A")
            assertTrue(repLoaded.contains("Snare Top") && repLoaded.contains("UA 1176LN Rev E"), "Must list Snare Top 1176")
            assertTrue(repLoaded.contains("Session DSP Summary"), "Must report session DSP summary")

            // 3. "plugins on Lead Vox" (track-specific plugin layout)
            var repTrack = ""
            chat.processQuery(query: "plugins on Lead Vox", uad: uad, auditor: auditor) { rep in
                repTrack = rep
            }
            assertTrue(repTrack.contains("Plug-ins & Inserts for Track 1 (Lead Vox)"), "Must produce Lead Vox plugin report")
            assertTrue(repTrack.contains("Slot 0 (UNISON)") && repTrack.contains("UA 610-A"), "Must list Slot 0 Unison")
            assertTrue(repTrack.contains("Slot 1 (Insert 1)") && repTrack.contains("Teletronix LA-2A Gray"), "Must list Slot 1 LA-2A")
            assertTrue(repTrack.contains("Peak Reduction"), "Must display parameter readout")
            assertTrue(repTrack.contains("Slot 2 (Insert 2)") && repTrack.contains("Precision EQ") && repTrack.contains("Bypassed"), "Must list Precision EQ as bypassed")
            assertTrue(repTrack.contains("Slot 3 (Insert 3)") && repTrack.contains("Empty"), "Must list empty slots")

            // 4. "show unison plugins"
            var repUnison = ""
            chat.processQuery(query: "show unison plugins", uad: uad, auditor: auditor) { rep in
                repUnison = rep
            }
            assertTrue(repUnison.contains("Unison Preamp Modeling Status"), "Must produce Unison status")
            assertTrue(repUnison.contains("Lead Vox") && repUnison.contains("UA 610-A"), "Must list Lead Vox Unison model")
            assertTrue(repUnison.contains("Unison Summary"), "Must produce Unison summary")

            // 5. "which plugins are bypassed?"
            var repBypassed = ""
            chat.processQuery(query: "which plugins are bypassed?", uad: uad, auditor: auditor) { rep in
                repBypassed = rep
            }
            assertTrue(repBypassed.contains("Bypassed UAD Plug-ins"), "Must list bypassed plugins")
            assertTrue(repBypassed.contains("Precision EQ"), "Must list Precision EQ")

            // 6. Direct plugin bypass command: "bypass insert 1 on track 1"
            var repBypassCmd = ""
            chat.processQuery(query: "bypass insert 1 on track 1", uad: uad, auditor: auditor) { rep in
                repBypassCmd = rep
            }
            assertTrue(repBypassCmd.contains("Bypassed Insert 1"), "Must confirm bypass")
            assertFalse(ch0.effects[0]?.power ?? true, "Insert 1 power must be false after bypass")

            // 7. Direct plugin enable command: "enable insert 1 on track 1"
            var repEnableCmd = ""
            chat.processQuery(query: "enable insert 1 on track 1", uad: uad, auditor: auditor) { rep in
                repEnableCmd = rep
            }
            assertTrue(repEnableCmd.contains("Enabled Insert 1"), "Must confirm enable")
            assertTrue(ch0.effects[0]?.power == true, "Insert 1 power must be true after enable")

            // 8. Direct plugin bypass by plugin name: "bypass LA-2A on Lead Vox"
            var repNameBypass = ""
            chat.processQuery(query: "bypass LA-2A on Lead Vox", uad: uad, auditor: auditor) { rep in
                repNameBypass = rep
            }
            assertTrue(repNameBypass.contains("Bypassed"), "Must confirm named plugin bypass")
            assertFalse(ch0.effects[0]?.power ?? true, "LA-2A must be bypassed")

            // 9. Global plugin enable: "enable all plugins"
            var repEnableAll = ""
            chat.processQuery(query: "enable all plugins", uad: uad, auditor: auditor) { rep in
                repEnableAll = rep
            }
            assertTrue(repEnableAll.contains("Enabled All Plug-ins"), "Must confirm enabling all plugins")
            assertTrue(ch0.effects[0]?.power == true, "Insert 0 must be enabled")
            assertTrue(ch0.effects[1]?.power == true, "Insert 1 must be enabled")
            assertTrue(ch0.unisonEffect.power == true, "Unison effect must be enabled")
            assertTrue(ch1.effects[0]?.power == true, "Ch 1 Insert 0 must be enabled")

            // 10. Global plugin bypass: "bypass all plugins"
            var repBypassAll = ""
            chat.processQuery(query: "bypass all plugins", uad: uad, auditor: auditor) { rep in
                repBypassAll = rep
            }
            assertTrue(repBypassAll.contains("Bypassed All Plug-ins"), "Must confirm bypassing all plugins")
            assertFalse(ch0.effects[0]?.power ?? true, "Insert 0 must be bypassed")
            assertFalse(ch0.effects[1]?.power ?? true, "Insert 1 must be bypassed")
            assertFalse(ch0.unisonEffect.power, "Unison effect must be bypassed")
            assertFalse(ch1.effects[0]?.power ?? true, "Ch 1 Insert 0 must be bypassed")

            // 11. Channel-wide plugin enable: "enable all plugins on Lead Vox"
            var repEnableLead = ""
            chat.processQuery(query: "enable all plugins on Lead Vox", uad: uad, auditor: auditor) { rep in
                repEnableLead = rep
            }
            assertTrue(repEnableLead.contains("Enabled All Plug-ins") && repEnableLead.contains("Track 1"), "Must confirm enabling plugins on track 1")
            assertTrue(ch0.effects[0]?.power == true, "Track 1 insert 0 must be enabled")
            assertTrue(ch0.unisonEffect.power == true, "Track 1 Unison must be enabled")
            assertFalse(ch1.effects[0]?.power ?? true, "Track 2 plugins must remain unchanged")

            // 12. Direct parameter setting by ratio: "set ratio to 8:1 on Snare Top"
            var repRatio = ""
            chat.processQuery(query: "set ratio to 8:1 on Snare Top", uad: uad, auditor: auditor) { rep in
                repRatio = rep
            }
            assertTrue(repRatio.contains("Ratio") || repRatio.contains("parameter"), "Must acknowledge ratio setting")
            let snareRatioVal = effSnare.parameters[2]?.normVal ?? 0.0
            assertTrue(abs(snareRatioVal - 0.333) < 0.01, "Ratio 8:1 must set normalized value to ~0.333")

            // 13. Direct parameter setting by percentage: "set peak reduction to 60 on Lead Vox"
            var repPeak = ""
            chat.processQuery(query: "set peak reduction to 60 on Lead Vox", uad: uad, auditor: auditor) { rep in
                repPeak = rep
            }
            assertTrue(repPeak.contains("Peak Reduction") || repPeak.contains("parameter"), "Must acknowledge peak reduction setting")
            assertEqual(eff0.parameters[0]?.normVal ?? 0.0, 0.60, "Peak Reduction must be set to 0.60 (60%)")

            // 14. Direct parameter setting by percentage with symbol: "set plugin gain to 75% on Lead Vox"
            var repGain = ""
            chat.processQuery(query: "set plugin gain to 75% on Lead Vox", uad: uad, auditor: auditor) { rep in
                repGain = rep
            }
            assertTrue(repGain.contains("Gain") || repGain.contains("parameter"), "Must acknowledge gain setting")
            assertEqual(eff0.parameters[1]?.normVal ?? 0.0, 0.75, "Gain must be set to 0.75 (75%)")

            // 15. Undo restores previous plugin power and parameter values: "undo"
            var repUndo = ""
            chat.processQuery(query: "undo", uad: uad, auditor: auditor) { rep in
                repUndo = rep
            }
            assertTrue(repUndo.contains("Undid"), "Undo must succeed")
            assertEqual(eff0.parameters[1]?.normVal ?? 0.0, 0.60, "Gain must be restored to previous value 0.60")

            // 16. Redo reapplies the parameter change: "redo"
            var repRedo = ""
            chat.processQuery(query: "redo", uad: uad, auditor: auditor) { rep in
                repRedo = rep
            }
            assertTrue(repRedo.contains("Redid"), "Redo must succeed")
            assertEqual(eff0.parameters[1]?.normVal ?? 0.0, 0.75, "Gain must be reapplied to 0.75")

            // 17. Combined Power Toggle & Value Change: "change the plugin settings like on and off, value changes etc."
            let initialPower = eff0.power
            var repCombined = ""
            chat.processQuery(query: "change the plugin settings like on and off, value changes etc.", uad: uad, auditor: auditor) { rep in
                repCombined = rep
            }
            assertTrue(repCombined.contains("Plugin Power & Settings Updated"), "Combined query must confirm both updates")
            assertEqual(eff0.power, !initialPower, "Plugin power must be inverted by on/off request")
            assertTrue((eff0.parameters[0]?.normVal ?? 0.0) > 0.0, "Plugin parameter must be updated")

            // 18. Preposition 'on' must not falsely trigger enable: "bypass insert 1 on track 1"
            chat.processQuery(query: "enable insert 1 on track 1", uad: uad, auditor: auditor) { _ in }
            assertTrue(eff0.power, "Insert 1 must be enabled")
            chat.processQuery(query: "bypass insert 1 on track 1", uad: uad, auditor: auditor) { _ in }
            assertFalse(eff0.power, "'bypass insert 1 on track 1' must bypass, not enable (on track trap resolved)")

            // 19. Semantic power action resolution test
            assertTrue(AIChatEngine.determinePowerAction(in: "bypass insert 1 on track 1", currentPower: true) == false, "bypass must resolve to false")
            assertTrue(AIChatEngine.determinePowerAction(in: "disable LA-2A on Lead Vox", currentPower: true) == false, "disable must resolve to false")
            assertTrue(AIChatEngine.determinePowerAction(in: "turn off plugin on vocal", currentPower: true) == false, "turn off must resolve to false")
            assertTrue(AIChatEngine.determinePowerAction(in: "turn on plugin on vocal", currentPower: false) == true, "turn on must resolve to true")
            assertTrue(AIChatEngine.determinePowerAction(in: "toggle LA-2A", currentPower: false) == true, "toggle must flip false to true")

            // 20. Reset Plugin Settings: "reset plugin settings on Lead Vox"
            var repReset = ""
            chat.processQuery(query: "reset plugin settings on Lead Vox", uad: uad, auditor: auditor) { rep in
                repReset = rep
            }
            assertTrue(repReset.contains("Reset Plug-in Settings"), "Must confirm settings reset")
            assertEqual(eff0.parameters[0]?.normVal ?? 0.0, 0.5, "Peak Reduction must be reset to 0.50 (nominal)")
            assertEqual(eff0.parameters[1]?.normVal ?? 0.0, 0.5, "Gain must be reset to 0.50 (nominal)")
        }
    }

    /// Test Chat Input Field Copy/Paste, Right-Click Context Menu & AIChatWindow Event Routing
    public static func testChatInputFieldCopyPasteAndAIChatWindow() {
        runTest("P0: Chat Input Field: Copy/Paste actions, Context Menu & AIChatWindow Cmd+V/C routing") {
            let (mcu, uad, _) = TestAudioFixture.makeMCUEngine(channelCount: 8)
            let controller = AIChatWindowController(uad: uad, auditor: mcu.auditor)

            // 1. Verify inputField type and properties
            assertTrue(controller.inputField != nil, "inputField must not be nil")

            // 2. Test direct paste action
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("mute C2 level for System out", forType: .string)
            controller.inputField.stringValue = ""
            controller.inputField.paste(nil)
            assertEqual(controller.inputField.stringValue, "mute C2 level for System out", "inputField.paste() must insert clipboard content")

            // 3. Test direct copy action
            controller.inputField.stringValue = "how to reset fader to unity"
            controller.inputField.copy(nil)
            assertEqual(NSPasteboard.general.string(forType: .string), "how to reset fader to unity", "inputField.copy() must write to clipboard")

            // 4. Test direct cut action
            controller.inputField.cut(nil)
            assertEqual(controller.inputField.stringValue, "", "inputField.cut() must clear text")
            assertEqual(NSPasteboard.general.string(forType: .string), "how to reset fader to unity", "cut text must remain in clipboard")

            // 5. Test context menu on right click
            let dummyEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0)!
            let menu = controller.inputField.menu(for: dummyEvent)
            assertTrue(menu != nil, "inputField must provide contextual menu for right click")
            let titles = menu?.items.map { $0.title } ?? []
            assertTrue(titles.contains("Copy"), "Context menu must contain Copy")
            assertTrue(titles.contains("Paste"), "Context menu must contain Paste")
            assertTrue(titles.contains("Cut"), "Context menu must contain Cut")
            assertTrue(titles.contains("Select All"), "Context menu must contain Select All")

            // 6. Test AIChatWindow Cmd+V event routing
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("tell me channels in Overloaded", forType: .string)
            controller.inputField.stringValue = ""
            if let win = controller.window as? AIChatWindow {
                win.makeFirstResponder(controller.inputField)
                let keyEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: win.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
                win.sendEvent(keyEvent)
                assertEqual(controller.inputField.stringValue, "tell me channels in Overloaded", "AIChatWindow must route Cmd+V to paste into active field")
            } else {
                assertTrue(false, "controller.window must be instance of AIChatWindow")
            }
        }
    }

    /// Test AIPromptCatalog data integrity, 8 categories, and search/filtering
    public static func testPromptCatalogDataIntegrityAndCategories() {
        runTest("P0: Prompt Catalog: 38+ detailed examples across 8 categories with search & help summary") {
            // 1. Total items count
            assertTrue(AIPromptCatalog.all.count >= 36, "AIPromptCatalog must contain at least 36 prompt examples (found \(AIPromptCatalog.all.count))")

            // 2. Category coverage: Every category has at least 3 examples
            for cat in AIPromptExample.Category.allCases {
                let items = AIPromptCatalog.byCategory(cat)
                assertTrue(items.count >= 3, "Category '\(cat.rawValue)' must contain at least 3 examples (found \(items.count))")
            }

            // 3. Highlighted items: exactly 1 per category (8 total)
            let highlighted = AIPromptCatalog.highlighted
            assertEqual(highlighted.count, AIPromptExample.Category.allCases.count, "Highlighted prompt count must match number of categories")
            let highlightedCategories = Set(highlighted.map { $0.category })
            assertEqual(highlightedCategories.count, AIPromptExample.Category.allCases.count, "Each category must have exactly one highlighted example")

            // 4. Detailed fields validation
            for item in AIPromptCatalog.all {
                assertFalse(item.id.isEmpty, "Item id must not be empty")
                assertFalse(item.title.isEmpty, "Item title must not be empty")
                assertFalse(item.prompt.isEmpty, "Item prompt must not be empty")
                assertFalse(item.description.isEmpty, "Item description must not be empty")
                assertFalse(item.hardwareEffect.isEmpty, "Item hardwareEffect must not be empty")
            }

            // 5. Search by query
            let searchUnity = AIPromptCatalog.search(query: "unity")
            assertTrue(searchUnity.contains { $0.prompt.contains("unity") || $0.title.contains("Unity") }, "Search for 'unity' must match unity fader prompt")

            let searchOverload = AIPromptCatalog.search(query: "overload")
            assertTrue(searchOverload.contains { $0.prompt.contains("Overloaded") }, "Search for 'overload' must match overload scan prompt")

            // 6. Search filtered by category
            let cueOnly = AIPromptCatalog.search(query: "", category: .cueSends)
            assertEqual(cueOnly.count, AIPromptCatalog.byCategory(.cueSends).count, "Category-filtered search must return all items in that category")

            // 7. Markdown summary generation
            let summary = AIPromptCatalog.generateChatHelpSummary()
            assertTrue(summary.contains("S&D Co-Producer • Complete Prompt Examples"), "Summary must contain header")
            for cat in AIPromptExample.Category.allCases {
                assertTrue(summary.contains(cat.rawValue), "Summary must contain category '\(cat.rawValue)'")
            }
        }
    }

    /// Test dynamic contextual suggestions generation after executing prompts
    public static func testDynamicContextualSuggestionsGeneration() {
        runTest("P0: Dynamic Suggestions: Contextual suggestions adapt to last executed query and response") {
            // 1. Inventory / Channel list query
            let invSuggestions = AIPromptCatalog.computeContextualSuggestions(query: "Full list pls", reply: "🎛️ Universal Audio Apollo Full Channel Inventory...")
            let invPrompts = invSuggestions.map { $0.prompt }
            assertTrue(invPrompts.contains("Tell me channels in Overloaded"), "Inventory query must suggest overload scan")
            assertTrue(invPrompts.contains("Which channels have zero input?"), "Inventory query must suggest zero input detection")
            assertTrue(invPrompts.contains("Show CUE sends"), "Inventory query must suggest CUE sends")
            assertTrue(invPrompts.contains("Show plugins"), "Inventory query must suggest plugins")

            // 2. Overload query with clipping response -> suggests corrective fader & preamp actions
            let clipSuggestions = AIPromptCatalog.computeContextualSuggestions(
                query: "Tell me channels in Overloaded",
                reply: "⚠️ Overloaded Channels Detected (2): Vocal (0.0 dBFS), Snare (-0.1 dBFS)"
            )
            let clipPrompts = clipSuggestions.map { $0.prompt }
            assertTrue(clipPrompts.contains("Set -infinite dB for all channels"), "Clipping reply must suggest pulling down faders")
            assertTrue(clipPrompts.contains("How does Preamp Mode work on UF8?"), "Clipping reply must suggest preamp guide")
            assertTrue(clipPrompts.contains("listening 5 secs and check headroom"), "Clipping reply must suggest re-listening")
            assertTrue(clipPrompts.contains("Undo"), "Clipping reply must suggest Undo")

            // 3. Overload query with clean response -> suggests regular mix audit follow-ups
            let cleanSuggestions = AIPromptCatalog.computeContextualSuggestions(
                query: "Tell me channels in Overloaded",
                reply: "✅ No channels are currently in Overload. All active channels have clean headroom below 0 dBFS."
            )
            let cleanPrompts = cleanSuggestions.map { $0.prompt }
            assertTrue(cleanPrompts.contains("listening 10 secs and analyze incoming signals"), "Clean reply must suggest 10s listening")
            assertTrue(cleanPrompts.contains("Show CUE sends"), "Clean reply must suggest CUE sends")
            assertTrue(cleanPrompts.contains("Show plugins"), "Clean reply must suggest plugins")

            // 4. Zero input query -> suggests preamp checks and 48V
            let zeroSuggestions = AIPromptCatalog.computeContextualSuggestions(query: "Which channels have zero input?", reply: "🔇 Zero-Input Channels Detected (4)...")
            let zeroPrompts = zeroSuggestions.map { $0.prompt }
            assertTrue(zeroPrompts.contains("Turn on 48V on track 1"), "Zero input query must suggest 48V phantom check")
            assertTrue(zeroPrompts.contains("Tell me channels in Overloaded"), "Zero input query must suggest overload check")

            // 5. CUE Sends query -> suggests CUE 1, CUE 2, Sends Focus Mode
            let cueSuggestions = AIPromptCatalog.computeContextualSuggestions(query: "Show CUE sends", reply: "🎧 Apollo CUE Sends Matrix...")
            let cuePrompts = cueSuggestions.map { $0.prompt }
            assertTrue(cuePrompts.contains("Show CUE 1 sends"), "CUE query must suggest CUE 1")
            assertTrue(cuePrompts.contains("Show Sends Focus Mode guide"), "CUE query must suggest Sends Focus Mode guide")

            // 6. Plugin query -> suggests Unison and bypassed plugins
            let plugSuggestions = AIPromptCatalog.computeContextualSuggestions(query: "Show plugins", reply: "🔌 Active UAD-2 DSP Plug-in Inventory...")
            let plugPrompts = plugSuggestions.map { $0.prompt }
            assertTrue(plugPrompts.contains("Show Unison plugins"), "Plugin query must suggest Unison preamps")
            assertTrue(plugPrompts.contains("Which plugins are bypassed?"), "Plugin query must suggest bypassed plugins")

            // 7. Preamp query -> suggests Preamp mode guide, 48V, low cut
            let preSuggestions = AIPromptCatalog.computeContextualSuggestions(query: "Turn on 48V on track 1", reply: "⚡ +48V phantom power engaged on Track 1.")
            let prePrompts = preSuggestions.map { $0.prompt }
            assertTrue(prePrompts.contains("How does Preamp Mode work on UF8?"), "Preamp query must suggest Preamp mode guide")
            assertTrue(prePrompts.contains("Low cut on vocal"), "Preamp query must suggest low-cut filter")

            // 8. Fader query -> suggests Undo and 0 dB unity
            let fadSuggestions = AIPromptCatalog.computeContextualSuggestions(query: "Set track 1 to 0 dB", reply: "🎚️ Track 1 fader set to 0.0 dB.")
            let fadPrompts = fadSuggestions.map { $0.prompt }
            assertTrue(fadPrompts.contains("Undo"), "Fader query must suggest Undo")
            assertTrue(fadPrompts.contains("How do I reset faders to 0 dB unity on UF8?"), "Fader query must suggest unity reset guide")

            // 9. Timed Listening query -> suggests rough mix and CUE check
            let listenSuggestions = AIPromptCatalog.computeContextualSuggestions(query: "listening 10 secs and analyze incoming signals", reply: "📋 Acoustic Analysis Completed...")
            let listenPrompts = listenSuggestions.map { $0.prompt }
            assertTrue(listenPrompts.contains("Rough mix"), "Listening query must suggest rough mix")
            assertTrue(listenPrompts.contains("Show CUE sends"), "Listening query must suggest CUE sends")

            // 10. Fallback query
            let defSuggestions = AIPromptCatalog.computeContextualSuggestions(query: "", reply: "")
            assertTrue(defSuggestions.count >= 6, "Default suggestions must provide at least 6 chips")
        }
    }

    /// Test Prompt Help Page UI, initial screen banner, and 'help' query routing
    public static func testPromptHelpPageUIAndQueryTrigger() {
        runTest("P0: Help Page UI: Initial screen hero banner, 'help' query trigger, and Help Window Controller") {
            let (mcu, uad, _) = TestAudioFixture.makeMCUEngine(channelCount: 8)
            let controller = AIChatWindowController(uad: uad, auditor: mcu.auditor)

            // 1. isPromptExamplesQuery matcher validation
            assertTrue(AIChatEngine.isPromptExamplesQuery("help"), "'help' must trigger prompt examples")
            assertTrue(AIChatEngine.isPromptExamplesQuery("prompts"), "'prompts' must trigger prompt examples")
            assertTrue(AIChatEngine.isPromptExamplesQuery("prompt examples"), "'prompt examples' must trigger prompt examples")
            assertTrue(AIChatEngine.isPromptExamplesQuery("commands"), "'commands' must trigger prompt examples")
            assertTrue(AIChatEngine.isPromptExamplesQuery("command guide"), "'command guide' must trigger prompt examples")
            assertTrue(AIChatEngine.isPromptExamplesQuery("show prompt examples"), "'show prompt examples' must trigger prompt examples")
            assertFalse(AIChatEngine.isPromptExamplesQuery("mute track 1"), "'mute track 1' must not trigger prompt examples")

            // 2. Natural language 'help' query execution
            var helpResponse = ""
            var helpNotified = false
            let observer = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("ShowAIPromptHelpNotification"),
                object: nil,
                queue: nil
            ) { _ in
                helpNotified = true
            }

            AIChatEngine.shared.processQuery(query: "prompt examples", uad: uad, auditor: mcu.auditor) { response in
                helpResponse = response
            }
            NotificationCenter.default.removeObserver(observer)

            assertTrue(helpResponse.contains("S&D Co-Producer • Complete Prompt Examples"), "Response must return complete prompt guide")
            assertTrue(helpNotified, "Executing prompt examples query must post ShowAIPromptHelpNotification")

            // 3. Help Window Controller initialization & rendering
            let helpWin = AIPromptHelpWindowController.shared
            assertTrue(helpWin.window != nil, "AIPromptHelpWindowController window must exist")
            assertEqual(helpWin.window?.title, "S&D Co-Producer • Prompt Examples & Command Guide", "Help window title must match")
            helpWin.renderCards()

            // 4. Initial screen hero view structure
            controller.messages.removeAll()
            controller.renderCanvas()
            let heroSubviews = controller.canvasView.subviews
            assertTrue(!heroSubviews.isEmpty, "Canvas must render hero view when messages are empty")
            let hero = heroSubviews.first!
            let buttons = hero.subviews.compactMap { $0 as? NSButton }

            // Verify the banner button exists
            let bannerBtn = buttons.first { $0.title.contains("Browse Full Help Page of Prompt Examples") }
            assertTrue(bannerBtn != nil, "Hero view must contain Full Help Page banner button")

            // Verify categorized cards exist
            let cardButtons = hero.subviews.compactMap { $0 as? HeroCardButton }
            assertEqual(cardButtons.count, AIPromptCatalog.highlighted.count, "Hero view must display all highlighted categorized cards")

            // 5. Verification of suggestion card link button
            controller.messages.append(AIChatWindowController.ChatMessage(sender: .user, text: "Full list pls", timestamp: Date()))
            controller.messages.append(AIChatWindowController.ChatMessage(sender: .gemini, text: "Inventory list", timestamp: Date()))
            controller.renderCanvas()

            let canvasSubviews = controller.canvasView.subviews
            let suggestionCards = canvasSubviews.filter { $0 is FlippedCanvasView && $0.subviews.contains { ($0 as? NSTextField)?.stringValue.contains("Prompt Suggestions") ?? false } }
            assertTrue(!suggestionCards.isEmpty, "Canvas must render suggestion card after messages")
            let sugCard = suggestionCards.first!
            let sugButtons = sugCard.subviews.compactMap { $0 as? NSButton }
            let allExamplesBtn = sugButtons.first { $0.title.contains("All Examples ↗") }
            assertTrue(allExamplesBtn != nil, "Suggestions card must contain 'All Examples ↗' link button")

            // 6. Verification of Help Window Level & Left-Side Positioning
            guard let chatWin = controller.window, let helpWinObj = helpWin.window else {
                assertTrue(false, "Chat window and Help window must both exist")
                return
            }
            chatWin.setFrame(NSRect(x: 1000, y: 100, width: 680, height: 740), display: false)
            helpWin.showHelp(relativeTo: chatWin)

            assertEqual(helpWinObj.level, NSWindow.Level.floating, "Help window level must be floating to stay in front of chat window")
            assertTrue(helpWinObj.frame.maxX <= chatWin.frame.minX, "Help window must be positioned to the left of the chat window (help.maxX: \(helpWinObj.frame.maxX), chat.minX: \(chatWin.frame.minX))")

            // 7. Verification of Chat Window Status Bar Anchoring
            AIChatWindowController.statusItemFrameProvider = {
                return NSRect(x: 1200, y: 980, width: 30, height: 22)
            }
            controller.positionNearStatusBar()
            let anchoredFrame = chatWin.frame
            assertTrue(anchoredFrame.minY < 980, "Chat window must be positioned below status bar icon")
            AIChatWindowController.statusItemFrameProvider = nil
        }
    }

    /// Test Local LLM (Ollama / Llama 3.2), Provider switching, and auto-fallback
    public static func testLocalLLMAndOllamaProviderConfiguration() {
        runTest("P0: Local LLM (Ollama) provider switching, custom endpoint/model, and offline fallback") {
            let engine = AIChatEngine.shared
            let prevProvider = engine.aiProvider
            let prevEndpoint = engine.ollamaEndpoint
            let prevModel = engine.ollamaModel

            // 1. Default properties
            let newEngine = AIChatEngine()
            assertEqual(newEngine.aiProvider, "local", "Default aiProvider must be local")
            assertTrue(newEngine.preferLocalLLMOverTelemetry, "preferLocalLLMOverTelemetry must be true by default")
            assertEqual(newEngine.ollamaEndpoint, "http://127.0.0.1:11434", "Default endpoint must be http://127.0.0.1:11434")
            assertEqual(newEngine.ollamaModel, "llama3.2", "Default model must be llama3.2")

            // 2. Provider switching
            engine.aiProvider = "local"
            assertEqual(engine.aiProvider, "local", "aiProvider must be set to local")

            engine.aiProvider = "gemini"
            assertEqual(engine.aiProvider, "gemini", "aiProvider must be set to gemini")

            engine.aiProvider = "auto"
            assertEqual(engine.aiProvider, "auto", "aiProvider must be set to auto")

            // 3. Custom endpoint and model
            engine.ollamaEndpoint = "http://localhost:11434"
            assertEqual(engine.ollamaEndpoint, "http://localhost:11434", "Endpoint must update")

            engine.ollamaModel = "llama3.2:3b"
            assertEqual(engine.ollamaModel, "llama3.2:3b", "Model must update")

            // 4. Model Badge Updates in AIChatWindowController
            let (mcu, uad, _) = TestAudioFixture.makeMCUEngine(channelCount: 8)
            let controller = AIChatWindowController(uad: uad, auditor: mcu.auditor)

            engine.aiProvider = "local"
            controller.updateModelBadge()

            engine.aiProvider = "gemini"
            controller.updateModelBadge()

            engine.aiProvider = "auto"
            controller.updateModelBadge()

            // 5. Test Mixer Telemetry Context Generation for Local LLM
            let ch0 = uad.channels[0]!
            ch0.name = "Kick"
            ch0.meterPeak = 0.0 // Clipping
            ch0.meterClip = true

            let ch1 = uad.channels[1]!
            ch1.name = "Snare"
            ch1.meterPeak = -144.0 // Silent / Zero-input

            let ch2 = uad.channels[2]!
            ch2.name = "Lead Vox"
            ch2.meterPeak = -12.4 // Active signal
            ch2.preamp.hasPreamp = true
            ch2.preamp.gain = 38.0
            ch2.preamp.phantom48V = true
            ch2.preamp.lowCut = true
            ch2.unisonEffect.name = "Neve 1073"
            ch2.unisonEffect.power = true
            let eff1 = UADEffect(index: 0, isUnison: false)
            eff1.name = "1176LN Legacy"
            eff1.power = true
            ch2.effects[0] = eff1

            let telemetrySummary = engine.generateMixerTelemetrySummaryForLLM(uad: uad, auditor: mcu.auditor)
            assertTrue(telemetrySummary.contains("OVERLOADED / CLIPPING TRACKS"), "Must identify clipping tracks in LLM context")
            assertTrue(telemetrySummary.contains("Kick"), "Must include Kick in clipping tracks")
            assertTrue(telemetrySummary.contains("ZERO-INPUT / SILENT TRACKS"), "Must identify silent tracks in LLM context")
            assertTrue(telemetrySummary.contains("Snare"), "Must include Snare in silent tracks")
            assertTrue(telemetrySummary.contains("ACTIVE AUDIO STREAMS"), "Must identify active tracks in LLM context")
            assertTrue(telemetrySummary.contains("Lead Vox"), "Must include Lead Vox in active tracks")
            assertTrue(telemetrySummary.contains("Preamp: [Gain: 38.0 dB, +48V ON, 75Hz Low Cut]"), "Must format preamp details")
            assertTrue(telemetrySummary.contains("Neve 1073 (Active)"), "Must format Unison plugin")
            assertTrue(telemetrySummary.contains("1176LN Legacy (Active)"), "Must format insert plugin")

            // 6. Test executeOllamaGenerate fallback with invalid endpoint
            let prevEp = engine.ollamaEndpoint
            engine.ollamaEndpoint = "http://invalid-host-9999:1234"
            let fallbackSema = DispatchSemaphore(value: 0)
            var fallbackReceived = ""
            engine.executeOllamaGenerate(prompt: "Which channels have zero input?", uad: uad, auditor: mcu.auditor, fallback: {
                return "FALLBACK_TELEMETRY_TABLE"
            }) { reply in
                fallbackReceived = reply
            }
            let deadline = Date(timeIntervalSinceNow: 3.0)
            while fallbackReceived.isEmpty && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            assertEqual(fallbackReceived, "FALLBACK_TELEMETRY_TABLE", "Must invoke fallback when Local LLM is offline")
            engine.ollamaEndpoint = prevEp

            // 7. Test OllamaServiceManager running check with invalid endpoint
            let sema = DispatchSemaphore(value: 0)
            var reportedRunning = true
            OllamaServiceManager.shared.isOllamaRunning(endpoint: "http://invalid-host-9999:1234") { isRunning in
                reportedRunning = isRunning
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + 2.0)
            assertFalse(reportedRunning, "Invalid host must report not running")

            // Restore engine settings
            engine.aiProvider = prevProvider
            engine.ollamaEndpoint = prevEndpoint
            engine.ollamaModel = prevModel
        }
    }
}




