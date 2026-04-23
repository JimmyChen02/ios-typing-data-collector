import Foundation
import UIKit

// MARK: - DeviceInfo

struct DeviceInfo {
    static var modelName: String {
        let id = hardwareIdentifier
        return modelMap[id] ?? "iPhone (\(id))"
    }

    static var hardwareIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { bytes in
            bytes.compactMap { $0 == 0 ? nil : Character(UnicodeScalar($0)) }
                 .map(String.init).joined()
        }
    }

    // Maps hardware identifier → marketing name.
    // Unknown devices fall back to "iPhone (<identifier>)" so nothing is fabricated.
    private static let modelMap: [String: String] = [
        // iPhone SE
        "iPhone8,4":  "iPhone SE (1st gen)",
        "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone14,6": "iPhone SE (3rd gen)",
        // iPhone 6s
        "iPhone8,1":  "iPhone 6s",
        "iPhone8,2":  "iPhone 6s Plus",
        // iPhone 7
        "iPhone9,1":  "iPhone 7",
        "iPhone9,2":  "iPhone 7 Plus",
        "iPhone9,3":  "iPhone 7",
        "iPhone9,4":  "iPhone 7 Plus",
        // iPhone 8
        "iPhone10,1": "iPhone 8",
        "iPhone10,2": "iPhone 8 Plus",
        "iPhone10,4": "iPhone 8",
        "iPhone10,5": "iPhone 8 Plus",
        // iPhone X
        "iPhone10,3": "iPhone X",
        "iPhone10,6": "iPhone X",
        // iPhone XS / XR
        "iPhone11,2": "iPhone XS",
        "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        // iPhone 11
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        // iPhone 12
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        // iPhone 13
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        // iPhone 14
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        // iPhone 15
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        // iPhone 16
        "iPhone17,1": "iPhone 16",
        "iPhone17,2": "iPhone 16 Plus",
        "iPhone17,3": "iPhone 16 Pro",
        "iPhone17,4": "iPhone 16 Pro Max",
        // iPhone 16e
        "iPhone17,5": "iPhone 16e",
        // Simulator
        "i386":       "Simulator (x86)",
        "x86_64":     "Simulator (x86_64)",
        "arm64":      "Simulator (arm64)",
    ]

    static var systemVersion: String {
        UIDevice.current.systemVersion
    }

    static var screenWidthPt: Double {
        Double(UIScreen.main.bounds.width)
    }

    static var screenHeightPt: Double {
        Double(UIScreen.main.bounds.height)
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

// MARK: - WordGenerator

struct WordGenerator {
    // MARK: Corpus sets — one is chosen at random per session

    static let corpusSets: [[String]] = [
        // MARK: Set 1 — Academic & Campus
        [
            "jake reviewed his notes for the quiz and kept every key term on a single index card.",
            "the professor asked a very quick question about voltage and the class gave a clear answer.",
            "zoe fixed the display settings and moved the extra keyboard to a shelf beside the desk.",
            "we organized the project files by size, joined the call, and gave an update to the team.",
            "she solved the complex equation quite quickly and explained every step to the junior group.",
            "kevin took the job back in january and kept a very detailed log of every task since then.",
            "the exam had six questions covering a broad mix of topics from the required reading list.",
            "she revised her draft and realized the conclusion needed a stronger, more vivid final line.",
            "both professors put the problem on the board and asked us to work through it before class.",
            "the study group met every morning to review the material before the big midterm.",
            "my plan was to finish the chapter, but i spent more time on the problems than expected.",
            "she printed five copies of the report and passed them out at the beginning of the meeting.",
            "the faculty board approved the new building plan and gave the final go-ahead by friday.",
            "we worked through four problems before the professor stopped and moved to the next section.",
            "most of the work was done in the first few weeks, well before every final submission was due.",
            "the feedback from every group member was carefully written and submitted before the deadline.",
            "you should back up your work, review every draft, and bring a printed copy to the group meeting.",
            "the professor reminded every student to bring a fully charged laptop and a backup power supply.",
            "he put together a very brief summary of the main points and posted it to the class webpage.",
            "we mapped out the project timeline, divided responsibilities, and set a firm deadline for each part.",
            "after the quiz, she stepped outside for a very brief walk before her next seminar began.",
            "by comparing both methods, the group found the most effective problem-solving approach.",
            "the building lobby was very busy with students preparing for their morning presentations.",
            "she borrowed three books from the library and reviewed every chapter between afternoon classes.",
            "the most effective approach was to break the problem into smaller parts and solve each one in turn.",
            "kevin checked his weekly notebook and marked each key task with a quick tick before moving on.",
        ],

        // MARK: Set 2 — Nature & Outdoors
        [
            "the frozen peaks gave the valley a quiet, vivid quality that jack had never seen before.",
            "zach hiked to the lake at zero degrees and kept a journal of every bird spotted along the path.",
            "we drove the extra van quickly along the river road and stopped just before the old bridge.",
            "she visited six unique zones in the forest and took very careful notes along the trail.",
            "the ranger asked every visitor to keep to the marked path and avoid the frozen creek.",
            "the expedition required six days of planning, and zach gave the whole team a very clear map.",
            "jake found a quiet spot by the rocks and relaxed for the rest of a very warm afternoon.",
            "they kayaked across the calm bay and joked that every kilometer felt like a quick victory.",
            "both trails were beautiful but the upper path offered a better view of the surrounding peaks.",
            "before setting off, we packed breakfast, filled every water bottle, and put on fresh sunblock.",
            "the brown bear moved between the pines and disappeared behind a big cluster of boulders.",
            "big birds circled above the cliffs, probably looking for fish below the surface of the river.",
            "we built a small fire over the rocks beside the stream and boiled water for morning coffee.",
            "the map showed a broad flat plain beyond the forest, about five miles from the base camp.",
            "by the time the group reached the summit, most of the morning fog had blown away completely.",
            "the forest floor was thick with fallen branches, making progress slow but very rewarding.",
            "she photographed every plant species she found, from bright yellow flowers to brown mossy logs.",
            "the broken path forced the group to scramble over boulders before reaching the open ridge.",
            "we camped beside a wide bend in the river and watched the bright stars from our sleeping bags.",
            "the morning was perfect for hiking, with a bright blue sky and a warm but gentle wind.",
            "every step brought new sounds and smells, from pine resin to fresh mud by the stream bank.",
            "the birds were most active just before dawn, filling the valley below with a rich layered sound.",
            "we followed the slope down to a broad meadow where grazing deer moved slowly through the grass.",
            "the weather changed very quickly, so we put up every tent before the first drops of rain fell.",
            "a long climb brought us above the treeline, where the wide view opened up across the whole basin.",
        ],

        // MARK: Set 3 — Food & Social
        [
            "zoe made a very quick batch of vegetable soup and shared it with the neighbors next door.",
            "jake grilled six skewers of chicken and kept the extra sauce in a jar beside the grill.",
            "the jazz brunch at the hotel gave every visitor a welcome drink and a small gift box.",
            "she asked jake a quick question about the vegan options and quietly jotted the best items down.",
            "kevin brought six boxes of fruit from the market and stacked them in the kitchen corner.",
            "we joined to mix vivid sauces into the stew, tasted each one, and adjusted the flavor every time.",
            "zach drove to the juice bar, ordered the largest size, and sat near the front window.",
            "the quality of the event depended on how quickly every vendor had set up before guests arrived.",
            "both the bread and the pastry were baked fresh that morning, and neither was available by noon.",
            "she boiled the pasta, browned the butter, and brought everything to the table before the guests sat.",
            "the farmers brought big baskets of vegetables, berries, and fresh herbs to the saturday morning market.",
            "the barbecue beside the community building drew about fifty people from the surrounding neighborhood.",
            "we bought fresh fish, bright herbs, and ripe potatoes from the stall beside the park entrance.",
            "the warm bread was probably baked less than an hour before the shop opened, and it went fast.",
            "by the end of the meal, everybody had put their plates back and helped to clear the big table.",
            "the big pot of beans was perfect for a cold afternoon, and people kept coming back for more.",
            "she prepared a beautiful platter of melon, berries, and sliced peaches for the garden party.",
            "before the buffet opened, the manager briefly explained the full plan for the evening to every staff member.",
            "the whole group brought something to share, from homemade bread to bottles of sparkling water.",
            "people began to fill the square around noon, drawn by the smell of fresh bread and roasting spices.",
            "the market stays very busy from early morning until about three in the afternoon every day.",
            "by making small batches, the baker kept everything fresh and never let supply fall behind demand.",
            "a long table was set up beneath the trees, and people served themselves from wide bowls and big platters.",
            "the best part about the potluck was how many different dishes people brought from their own families.",
            "we booked a table for eight, but the place was so popular that we almost did not get a spot.",
            "kevin cooked a savory vegetable mix and served every bowl with a very vivid garnish on top.",
        ],

        // MARK: Set 4 — Tech & Problem Solving
        [
            "jake traced the exact bug, zeroed in on the issue, and fixed it before the review session.",
            "the quiz app required students to solve each problem quickly before viewing the next screen.",
            "zoe validated the data set, joined the team call, and organized each result into five categories.",
            "kevin found a very quick fix and gave the whole team a clear update on the key changes.",
            "the complex analysis required quite a lot of extra effort from every junior engineer.",
            "she gave a vivid demo and explained exactly how the job was solved in just three steps.",
            "the server crash was tracked back to a broken task in the job queue that nobody had reviewed.",
            "we fixed six data integrity bugs and ensured zero broken links across every live zone.",
            "both the frontend and backend teams worked through the problem carefully before the big deployment.",
            "the bug report described a broken form that blocked people from submitting their payment details.",
            "before shipping the update, every build was tested on multiple browsers and device types.",
            "by reviewing the base configuration, the team found a subtle problem in the boot sequence.",
            "the project board showed that about half the tasks were blocked by a missing dependency.",
            "a bad pointer in the library caused a memory overflow that brought down the backup service.",
            "the team rebuilt the pipeline from scratch because the previous build process was too brittle.",
            "debugging was slow at first, but the team made good progress once they broke the problem apart.",
            "the brief downtime gave the team a chance to review the deployment plan and fix minor gaps.",
            "we published the patch, updated the branch, and notified every affected subscriber by email.",
            "the build failed because a library had been removed from the public package repository.",
            "before the final merge, the team ran a complete test suite covering both new and old behavior.",
            "the backup system ran every night, but nobody had verified that the restore process still worked.",
            "a subtle bug was found by reviewing every branch that had been modified in the past week.",
            "the problem turned out to be a missing bracket in a block of code that nobody had touched.",
            "by being more precise about memory allocation, the team brought peak usage below acceptable limits.",
            "the update required every subscriber to reset their password before they could log back in.",
            "the team kept a working knowledge base and made sure every key workflow was clearly documented.",
        ],

        // MARK: Set 5 — Travel & Errands
        [
            "jake jumped on the early train and made it to the visa office just before the doors closed.",
            "zach packed six bags for the trip, checked every zipper twice, and locked the front door.",
            "the taxi queue moved very slowly, so she decided to walk the next five blocks instead.",
            "kevin drove across the valley and stopped to fix a small but critical problem with the axle.",
            "she gave the hotel a quick call to confirm the booking and ask about the extra parking fee.",
            "the express bus stopped at six zones before reaching the quiet junction near the harbor.",
            "we visited the jazz district, explored every street, and took vivid photos of the old buildings.",
            "zoe asked for an exact price quote on the job and kept copies of every required document.",
            "both bridges were blocked by traffic, so the driver took a back road through the outer suburbs.",
            "before boarding the bus, she bought a water bottle, a snack bar, and a brief travel guide.",
            "the big ferry was already pulling away from the berth when we arrived at the boat terminal.",
            "by the time we found a parking spot, most of the shops on the main street had begun to close.",
            "the bus broke down about three blocks from the station, so everybody had to walk the rest of the way.",
            "a bright billboard above the bridge described the public transport options between the two cities.",
            "we brought our biggest bags but still barely fit everything into the cabin storage above our seats.",
            "the bags were checked at the border, and one was briefly held because of a broken zipper.",
            "by booking both legs of the trip together, we saved a good amount on the total travel budget.",
            "the brief layover in the connecting city gave us enough time to grab a bite and buy a few things.",
            "the building beside the bus terminal had a bright sign with the schedule posted below the lobby clock.",
            "before leaving the country, she brought her passport to the correct bureau and renewed it in person.",
            "the boat bobbed gently at the dock, and the crew began loading the bigger cargo before sunrise.",
            "a broken signal light at the main bridge caused backups stretching almost all the way to the bypass.",
            "we bought breakfast from a small bakery beside the hotel and ate it on a bench in the courtyard.",
            "by checking the board at the station, she found a much faster route that saved about forty minutes.",
            "the group booked three adjoining rooms and brought everything they needed for a five-day stay.",
            "the small museum near the market was warm and welcoming, with many rooms of modern maritime photography.",
            "moving between terminals involved a very vivid overhead map and a moving walkway by the main entrance.",
        ],
    ]

    /// The corpus selected for the current session. Call `selectRandomCorpus()` at session start.
    static var currentCorpus: [String] = corpusSets[0]

    /// Picks a corpus set by cycling through available sets in order.
    static func selectCorpus(forSessionIndex index: Int) {
        currentCorpus = corpusSets[index % corpusSets.count]
    }

    /// Randomly picks one of the corpus sets for this session.
    static func selectRandomCorpus() {
        currentCorpus = corpusSets.randomElement() ?? corpusSets[0]
    }

    /// Returns `count` shuffled sentences from the current corpus joined by spaces.
    static func randomSentences(count: Int) -> String {
        var pool = currentCorpus.shuffled()
        var result: [String] = []
        var idx = 0
        for _ in 0..<count {
            result.append(pool[idx % pool.count])
            idx += 1
            if idx == pool.count { pool = currentCorpus.shuffled() }
        }
        return result.joined(separator: " ")
    }

    /// Legacy shim — converts a rough word count into a sentence count and delegates.
    static func randomString(wordCount: Int = 8) -> String {
        let sentenceCount = max(1, wordCount / 8)
        return randomSentences(count: sentenceCount)
    }
}

// MARK: - MetricsComputer

struct MetricsComputer {
    /// Positional character match accuracy at submission
    static func accuracy(target: String, typed: String) -> Double {
        guard !target.isEmpty else { return 0.0 }
        let targetChars = Array(target)
        let typedChars = Array(typed)
        var correct = 0
        let minLen = min(targetChars.count, typedChars.count)
        for i in 0..<minLen {
            if targetChars[i] == typedChars[i] {
                correct += 1
            }
        }
        return Double(correct) / Double(targetChars.count)
    }

    /// WPM = (chars / 5) / (durationSec / 60)
    static func wpm(charCount: Int, durationMs: Double) -> Double {
        guard durationMs > 0 else { return 0.0 }
        let durationSec = durationMs / 1000.0
        let words = Double(charCount) / 5.0
        return words / (durationSec / 60.0)
    }

    /// Characters per second
    static func charsPerSecond(charCount: Int, durationMs: Double) -> Double {
        guard durationMs > 0 else { return 0.0 }
        return Double(charCount) / (durationMs / 1000.0)
    }

    /// Count positionally correct characters
    static func correctCharCount(target: String, typed: String) -> Int {
        let targetChars = Array(target)
        let typedChars = Array(typed)
        var correct = 0
        let minLen = min(targetChars.count, typedChars.count)
        for i in 0..<minLen {
            if targetChars[i] == typedChars[i] {
                correct += 1
            }
        }
        return correct
    }
}
