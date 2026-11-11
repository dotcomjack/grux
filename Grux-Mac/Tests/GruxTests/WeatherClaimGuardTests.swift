import XCTest
@testable import Grux

/// W43-FIX round 2, live 2026-11-02 11:53 PM on qwen3.5:4b: "Will it rain in
/// May?" rightly went to the model (a month is not a place), and the model
/// answered "May, France, tomorrow: overcast with a 0% chance of rain. I'll
/// use May, France when you ask again.", copying the weather fast path's
/// replies earlier in the thread. The model has no weather tool, so a forecast
/// in its reply is made up. A local reply that states the weather, on a turn
/// with no web read, is replaced by a line saying how to get the real one.
@MainActor
final class WeatherClaimGuardTests: XCTestCase {

    private let none: [ActionClaimGuard.ToolResult] = []

    func testAForecastTheModelWroteIsReplaced() {
        for reply in [
            "May, France, tomorrow: overcast with a 0% chance of rain. I'll use May, France when you ask again.",
            "It'll be sunny and 75°F tomorrow.",
            "There's a 40% chance of rain later, so take an umbrella.",
            "Expect a high of 60 and showers in the afternoon.",
            "Boston is 48 °F and cloudy right now.",
            "It's about 12 degrees and snowing outside.",
        ] {
            let out = WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: nil, ask: "", previous: "")
            XCTAssertTrue(out.replaced, reply)
            XCTAssertEqual(out.text, WeatherClaimGuard.howToAsk(remembered: nil), reply)
        }
        let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.36, longitude: -71.06)
        let named = WeatherClaimGuard.vet(reply: "It'll be sunny and 75°F tomorrow.", route: "local",
                                          results: none, remembered: home, ask: "", previous: "")
        XCTAssertEqual(named.text, WeatherClaimGuard.howToAsk(remembered: home))
        XCTAssertTrue(named.text.contains("Boston, Massachusetts"))
        XCTAssertFalse(WeatherClaimGuard.howToAsk(remembered: nil).contains("\u{2014}"))
    }

    /// D153, live 2026-11-04 5:08 AM on grux-local:2b: "Will it rain at the
    /// beach?" (beach is not a place the fast path reads) got "I don't have
    /// access to real-time weather ...". Grux reads Open-Meteo with no model,
    /// so a local reply to a weather ask saying it cannot check the weather is
    /// false; it is replaced by what Grux can do. D148's live refusal too.
    func testARefusalToCheckTheWeatherIsReplaced() {
        let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.36, longitude: -71.06)
        let asks = ["Will it rain at the beach?", "What's the weather this weekend?", "Do I need an umbrella at the park?"]
        let refusals = [
            "I don't have access to real-time weather for your specific location. You'll need to check a weather app or website for that.",
            "I can't check the weather for you right now since I'm currently focused on backing up the Mini and in loginwindow mode.",
            "I'm unable to provide current weather forecasts.",
            "Sorry, I cannot look up the forecast.",
            "I'm not able to get live weather data, but you could check a weather service.",
            "I do not have a way to see the weather there.",
            // W50-FIX P2 2: the usual wordings the first pattern missed.
            "I don't have real-time weather information.",
            "Unfortunately I don't have live weather info.",
            "I have no real-time weather data.",
            "I couldn\u{2019}t get the weather.",
            "I won't be able to check the weather for you.",
            "I don\u{2019}t have access to the forecast.",
            // W50-FIX round 2 P2 4.
            "I'm sorry, but as an AI, I don't have the capability to check the weather.",
            "I am an AI and do not have access to real-time weather data.",
            "I'm not able to access real-time information. Please check a weather app.",
            "I'm not connected to the internet, so I can't see the weather.",
            "I have no way of knowing the weather.",
            "I don't know the weather there.",
            "I can't browse the web for the forecast.",
            "I've no access to the weather.",
            "We can't check the weather.",
            "Grux can't check the weather.",
            "I'm not able to get live weather data, but you could check a weather service.",
            // W50-FIX round 3 P2 2: a recommendation or an offer after "but",
            // long gaps, and another way of saying "I am an AI".
            "I don't have real-time weather data, but I recommend checking a weather app.",
            "I'm sorry, I can't check the weather, but I'd recommend checking a reliable weather website like Weather.com.",
            "I don't have access to real-time weather information, but I suggest checking a local weather website.",
            "I can't provide real-time weather updates, but you can find the forecast on weather.com.",
            "I can't check the weather, but you can easily check a weather app.",
            "I can't check the weather, but I can help you plan a beach day!",
            "I don't have live weather, though I can help with packing tips.",
            "I don't have the ability to access real-time data like weather forecasts.",
            "As an AI, I don't have the capability to access real-time data or check the weather.",
            "I don't have access to the internet or real-time information like weather forecasts.",
            "I do not have the ability to look up the current weather.",
            "I don't have the ability to browse the internet or access current weather conditions.",
            "I can't check the weather, it's beyond my capabilities.",
            "I'm sorry, I can't check the weather. That's beyond what I can do.",
            "I am a large language model and don't have access to real-time weather information.",
            // W50-FIX round 4 P2 2 and P3: real-time access, "I'm an AI and",
            // plain "have", offline, see or bring up the forecast.
            "I do not have real-time access to weather data.",
            "I don't have real-time access to weather information or forecasts.",
            "I don't have live access to weather data.",
            "Unfortunately, I don't have real-time access to the internet or weather data.",
            "I do not have real-time access to weather data, so please check a weather app.",
            "I'm an AI and don't have access to real-time weather data.",
            "I'm sorry, I'm an AI and don't have access to real-time weather data.",
            "I'm an AI assistant and don't have access to real-time weather information.",
            "I'm a language model and can't check the weather.",
            "I don't have weather data.",
            "I don't have any weather information.",
            "I don't have weather information for the beach.",
            "I do not have information about the weather.",
            "I am not connected to the internet and cannot check the weather.",
            "I'm offline and can't check the weather.",
            "I cannot see the forecast.",
            "I can't bring up the forecast.",
            // W50-FIX round 5 P2 2.
            "As an AI language model, I don't have access to real-time weather information.",
            "As an AI chatbot, I can't check the weather.",
            "I'm sorry, but I don't have the ability to provide real-time weather updates.",
            "I don't have the capability to provide weather forecasts.",
            "I don't have the ability to fetch weather data.",
            "I don't have access to real-time weather information. For the most accurate forecast, I recommend checking a weather app.",
            "I'm sorry, but I don't have access to real-time weather data. However, you can easily check the weather using a weather app or website.",
            "I'm sorry, but I don't have access to real-time weather information. To check the weather, you can use a weather app or website.",
            "I'm sorry, but I do not have access to real-time weather data. To find out if it will rain at the beach, check a local weather forecast.",
            "I'm sorry, I can't check the weather. You might want to check a weather app.",
            "Sorry, I don't have access to the internet, so I can't check the weather for you.",
            "I don't have internet access, so I can't check the weather.",
            // W50-FIX round 6: closing lines, access to real-time information
            // beside a pointer, pointer tails, and P3 wordings.
            "I'm sorry, but I can't check the weather. Let me know if there's anything else I can help with!",
            "I can't check the weather. Let me know if there is anything else I can do for you.",
            "I can't check the weather. I can help you with other tasks, like writing or answering questions.",
            "I can't check the weather. I hope this helps!",
            "I can't check the weather. However, I can help you with other questions!",
            "I can't check the weather. But I can help you with other things!",
            "I can't check the weather. If you have any other questions, feel free to ask!",
            "I don't have access to real-time information. Please check a weather app for the forecast.",
            "I do not have access to real-time information. Please check a weather app or website for the latest forecast.",
            "I don't have access to real-time data. Please check a weather app.",
            "I do not have access to real-time information, including weather forecasts.",
            "I'm sorry, but I don't have access to real-time weather information. I recommend checking a weather app before you head to the beach.",
            "I'm sorry, but I don't have access to real-time weather information. I recommend checking a weather app before you go.",
            "I'm sorry, but I don't have access to real-time weather information. I recommend checking a reliable weather website or app to stay up to date.",
            "I'm sorry, but I don't have access to real-time weather information. You can check a weather app to see what to expect.",
            "I can't check the weather. Check your local forecast before you go!",
            "I don't have real-time capabilities, so I can't check the weather.",
            "I'm sorry, I don't know the weather forecast for the beach.",
            "I don't have information about current weather conditions.",
            "I'm sorry, I don't have information about the current weather.",
            // Round 12 P3 (recall lost in round 12): a reason, then a pointer; near me.
            "I can't check the weather because I'm offline, but you can check a weather app.",
            "I can't check the weather since I'm offline, so please check a weather app.",
            "Sorry, I can't check the weather since I don't have internet access, but I recommend checking a weather app.",
            "I can't check the weather near me.",
            "I can't check the weather near you.",
            // W50-FIX round 7 P2 3: no real-time access, so cannot check.
            "I don't have access to real-time information, so I can't check the weather.",
            "As an AI, I don't have access to real-time data, so I can't check the weather for you. I recommend checking a weather app.",
            "As an AI language model, I do not have access to real-time information, so I cannot check the weather for you. Please check a weather app.",
            "I don't have real-time data, so I can't check the weather.",
            "I'm not able to access real-time information like weather forecasts.",
            "I'm not able to access real-time information, including weather forecasts.",
            "I can't access real-time data such as weather forecasts. Please check a weather app.",
            "I can't access real-time information like the weather.",
        ]
        for ask in asks {
            for reply in refusals {
                let out = WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: home,
                                                ask: ask, previous: "")
                XCTAssertTrue(out.replaced, "\(ask) -> \(reply)")
                XCTAssertEqual(out.text, WeatherClaimGuard.canCheck(remembered: home))
            }
        }
        XCTAssertEqual(WeatherClaimGuard.canCheck(remembered: home),
                       "I can check the weather: ask \u{201C}What's the weather?\u{201D} and I'll read Open-Meteo, "
                       + "a free weather service, for Boston, Massachusetts, or name a city.")
        XCTAssertEqual(WeatherClaimGuard.canCheck(remembered: nil),
                       "I can check the weather: ask \u{201C}What's the weather in\u{201D} and a city, "
                       + "and I'll read Open-Meteo, a free weather service.")
        // D157 item 16: a stranger has never heard of Open-Meteo, so every
        // pointer says what it is.
        for line in [WeatherClaimGuard.canCheck(remembered: home), WeatherClaimGuard.canCheck(remembered: nil),
                     WeatherClaimGuard.howToAsk(remembered: home), WeatherClaimGuard.howToAsk(remembered: nil)] {
            XCTAssertTrue(line.contains("Open-Meteo, a free weather service"), line)
        }
        // Left alone: an ask that is not about the weather, a web read, the
        // cloud, a refusal of something else, and talk about weather software.
        let refusal = refusals[0]
        XCTAssertFalse(WeatherClaimGuard.vet(reply: refusal, route: "local", results: none, remembered: home,
                                             ask: "Tell me a joke", previous: "").replaced)
        XCTAssertFalse(WeatherClaimGuard.vet(reply: refusal, route: "anthropic", results: none, remembered: home,
                                             ask: asks[0], previous: "").replaced)
        XCTAssertFalse(WeatherClaimGuard.vet(reply: refusal, route: "local",
                                             results: [("research_web", [:], "Rain likely, 70%.")],
                                             remembered: home, ask: asks[0], previous: "").replaced)
        for reply in [
            "I can't open the beach cam while headless, but bring a jacket.",
            "I don't have access to your calendar, so I can't say if you're free.",
            "I can't tell you how every weather API works, but most return JSON.",
            "Rain at the beach sounds lovely. Want a packing list?",
        ] {
            XCTAssertFalse(WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: home,
                                                 ask: "Will it rain at the beach? And how does the weather API work?",
                                                 previous: "").replaced, reply)
        }
    }

    /// W50-FIX P2 1: only Grux saying IT cannot get the weather is a refusal.
    /// Advice that reads Grux's own forecast just before ("I don't see heavy
    /// rain in the forecast"), a reminder to check the forecast, or a pointer
    /// to a weather app beside an answer is left alone.
    /// W50-FIX round 6 P3: a pathological reply must not stall the main
    /// actor on regex backtracking.
    func testALongRepeatedOpeningIsReadQuickly() {
        for reply in ["I can't check the weather. " + String(repeating: "To see ", count: 24) + "x.",
                      // Round 7 P3: the lead before a refusal.
                      String(repeating: "as an AI ", count: 30) + "x I can't check the weather.",
                      String(repeating: "as a bot ", count: 30) + "I can't check the weather.",
                      // Round 9: the filler after a refusal.
                      "I can't check the weather" + String(repeating: " on", count: 60) + " x y z w q.",
                      "I can't check the weather" + String(repeating: " for the", count: 60) + " x y z w q.",
                      // Round 10 P3: words that are both a place word and a filler.
                      "I can't check the weather" + String(repeating: " on today today", count: 30) + " x y z w q.",
                      "I can't check the weather" + String(repeating: " in Boston today,", count: 30) + " x y z w q.",
                      "I can't check the weather" + String(repeating: " at there there", count: 30) + " x y z w q.",
                      // Round 11 P3.
                      "I can't check the weather" + String(repeating: " for you", count: 30) + " x y z w q.",
                      "I can't check the weather" + String(repeating: " for me", count: 30) + " x y z w q.",
                      "I can't check the weather" + String(repeating: " at the moment", count: 30) + " x y z w q.",
                      // Round 13 P3: runs of commas or spaces.
                      "I can't check the weather" + String(repeating: ", ", count: 3000) + " x; y",
                      "I can't check the weather" + String(repeating: ",,,,", count: 3000) + " x; y",
                      "I can't check the weather" + String(repeating: " ", count: 6000) + "x"] {
            let start = Date()
            _ = WeatherClaimGuard.refusesWeather(reply, ask: "Will it rain?")
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, String(reply.prefix(30)))
        }
    }

    func testWeatherAdviceIsNotARefusal() {
        let home = WeatherPlace(name: "Boston, Massachusetts", latitude: 42.36, longitude: -71.06)
        let forecast = "Boston, Massachusetts, now: 48°F and clear. Today: light rain at times, high 55°F, low 41°F, 60% chance of rain."
        for reply in [
            "I don't see heavy rain in the forecast, but with a 60% chance I'd bring one.",
            "Don't forget to check the forecast before you head out.",
            "You won't need an umbrella; I don't see rain anywhere in today's forecast.",
            "It doesn't look like rain, but check a weather app to be sure.",
            "You'll want to check a local weather app for that.",
            "I can't tell you why weather apps disagree, but they use different models.",
            "I don't know whether forecasts are reliable that far out.",
            "I don't think the forecast changes much, so bring one.",
            "I can't promise the weather holds, but the forecast says light rain at times.",
            // Round 2 P2 1: an access word inside advice.
            "I don't see rain in the current forecast, so you can leave the umbrella.",
            "I don't think you'll need it, the current forecast only shows a 10% chance.",
            "I don't see any rain in the forecast, and the current weather is clear.",
            "I don't have live radar, but the forecast says light rain at times.",
            // Round 2 P2 2: a hedge before advice.
            "I can't say for sure the weather will hold, but 60% is high, so bring one.",
            "I can't say whether the weather will hold, but I'd bring one.",
            "I can't tell you the weather will stay dry, but the odds look good.",
            "I don't know if the weather will hold, but with a 60% chance I'd bring one.",
            "I don't know how the weather will turn out, but the forecast says 60%.",
            "I don't have the forecast for tonight in front of me but with a 60% chance I'd bring one.",
            // Round 2 P3.
            "I didn't say the weather would be sunny; I said light rain at times.",
            "I don't find the weather here too bad.",
            "I don't check the forecast every day, but today's looks clear.",
            // Round 3 P2 1: a hedge joined by "so", a semicolon or a comma.
            "I can't say whether the weather will hold, so I'd bring one to be safe.",
            "I don't know if the weather will hold, so I'd bring one.",
            "I can't predict the weather with certainty, so it's always smart to bring an umbrella.",
            "I can't tell you exactly what the weather will do, so pack an umbrella.",
            "I can't tell you the weather for certain; with a 60% chance I'd bring one.",
            "I don't have the forecast for tonight in front of me, so I'd bring one to be safe.",
            "I don't see any weather alerts for today, so you should be fine.",
            "I don't see the weather as a problem today, so go ahead.",
            // Hedge verbs (say, tell, know what it will be, predict) are left to
            // the model: small models hedge real advice with them. Only a claim
            // that Grux cannot get the weather is a refusal.
            "I can't predict the weather.",
            "I'm sorry, I can't say what the weather will be.",
            "I don't know what the weather will be like at the beach.",
            // Round 4 P2 1: a true refusal of something else.
            "I don't have real-time information about school closures. Check your district's website.",
            "I don't have live information about ferry delays, so call the terminal.",
            "I don't have real-time information on beach crowds. Weekends tend to be busy, so go early.",
            "I don't have current information about park closures; the forecast I gave says clear skies.",
            "I don't have access to airline systems to see whether the weather will delay your flight. Check your airline's app.",
            "I can't check flights for weather delays.",
            // Round 4 P3: advice that opens with an access phrase.
            "I can't check the weather every hour for you, so take an umbrella just in case.",
            "I can't read the forecast for your exact street, so plan for light rain.",
            "I can't get you a better forecast than Open-Meteo's, so I'd bring one.",
            "Since I don't have real-time data, go by the forecast above: light rain at times means bring an umbrella.",
            // Any sentence that is not a refusal, an apology, a pointer or an
            // offer keeps the whole reply.
            "Weekends at the beach are busy. I can't check the weather.",
            // Round 5 P2 1: advice after "but" or "so", or in its own sentence,
            // that opens like an offer or a pointer.
            "I can't check live weather, but I can tell you Boston in November is usually in the 40s to 50s.",
            "I don't have real-time weather data, but I can tell you that beaches are often windy in the afternoon.",
            "I can't check the weather, but you can bring an umbrella just in case.",
            "I can't check the weather, but you might want to pack a light jacket since evenings get cool.",
            "I can't check the weather, but please bring sunscreen; beach sun is strong.",
            "I can't check the weather, but try to go early before the crowds.",
            "I can't check the weather, so feel free to pack for both sun and rain.",
            "I can't check the weather. Feel free to bring an umbrella and a jacket just in case.",
            "I can't check the weather. I can help with packing tips: bring sunscreen, a hat, and plenty of water.",
            // Round 5 P3: a true refusal of something else.
            "I can't access weather radar.",
            "I can't get weather maps.",
            // Round 7 P2 1: a tip after a pointer or an offer.
            "I can't check the weather, so check a weather app and take a raincoat just in case.",
            "I can't check the weather, but check a weather app before you go and stay hydrated.",
            "I can't check live weather, so I'd suggest checking the forecast and leaving early to beat the crowds.",
            "I can't check the weather, but I can help with general tips: stay in the shade and take water.",
            "I can't check the weather, but I can help you plan: beaches are windy in the afternoon, so go early.",
            "I can't check the weather. However, I can help you plan around it: go in the morning when it's calmer.",
            "I don't have access to real-time weather information. I recommend checking a weather app, and if rain looks likely, take a raincoat.",
            "I can't check the weather, so check the forecast; if it says rain, stay home.",
            // Round 7 P2 2: a refusal of closures, delays or roads, pointing to their source.
            "I don't have access to real-time information. Please check your school district's website or local news for weather-related closures.",
            "I don't have access to real-time information. Please check your airline's website or app for the latest flight status and any weather delays.",
            "I'm sorry, I don't have access to real-time information. Please check your local DOT website for road conditions and weather alerts.",
            "I don't have access to real-time information. Please check the ferry operator's site for weather cancellations.",
            "I don't have access to real-time information. Please check the team's website for weather updates about the game.",
            // Round 8 P2 1: weather first in a list of other things refused.
            "I can't access real-time data such as weather or road conditions.",
            "I'm sorry, I can't access real-time information like weather, traffic, or flight status.",
            "I'm sorry, but I can't access real-time information such as weather updates or school closures.",
            "I can't access real-time information, including weather-related school closures.",
            "I don't have access to real-time information like weather or flight delays.",
            // Round 8 P2 2: "I don't know," then the weather is an answer.
            "I don't know, the weather there is usually mild.",
            "I don't know, the weather here changes fast.",
            // Round 8 P2 3: advice joined by "and", a semicolon or "which is why".
            "I can't check the weather, and I'd recommend bringing an umbrella just in case.",
            "I can't check the weather; bring an umbrella to be safe.",
            "I can't check the weather right now, and it's usually windy at the beach in the afternoon.",
            "I can't check the live weather, which is why I'd pack an umbrella.",
            "I can't check the weather, so bring an umbrella, since I can't check the forecast.",
            // Round 9 P2 1: a statement after a refusal, however joined.
            "I can't check the weather again; the forecast above says light rain at times.",
            "I can't check the live weather, and the forecast above says light rain at times.",
            "I can't check the weather for the beach itself; the forecast I gave for Boston says light rain at times.",
            "I can't check the weather at the beach specifically, and it should be similar to the city forecast.",
            "I can't look up the weather for the beach, which is likely similar to Boston's forecast above.",
            "I don't know the weather at the beach, it might be windier than in town.",
            "I can't check the weather, it looks fine from the forecast I gave.",
            // Round 9 P2 2: reassurance read from Grux's own forecast.
            "I don't see any weather in the forecast that should worry you.",
            "I don't see any weather in the forecast that would stop you.",
            "I don't see any weather there to worry about.",
            "I don't see the forecast for the beach, only for the city.",
            // Round 10 P2 1: advice after a reason.
            "I can't check the weather because I don't have internet access, and I'd recommend bringing an umbrella just in case.",
            "I can't check the weather since I'm offline; bring an umbrella to be safe.",
            "I can't check the weather as I don't have real-time access, and I'd pack a light jacket.",
            "I can't check the live weather because I'm offline, and Boston in November is usually in the 40s to 50s.",
            "I can't check the weather right now, as I don't have internet access, and it's usually chilly at the beach in the evening.",
            // Round 10 P2 2: a short statement after "in", "for the", "there".
            "I don't see any weather in the forecast that worries me.",
            "I don't see any weather in the forecast that concerns me.",
            "I don't see the weather in Boston getting worse.",
            "I don't see the forecast for the beach changing.",
            "I don't see the weather at the beach being different.",
            "I don't see the weather there as a problem.",
            // Round 11 P2: a statement after a reason, joined by a comma.
            "I can't check the live weather because I'm offline, and November in Boston can be chilly.",
            "I can't check the weather since I'm offline, and it's humid there this time of year.",
            "I can't check the weather right now, as I don't have internet access, and it might be cooler by the water.",
            "I can't check the weather because I'm offline, and storms are common there in the afternoon.",
            "I can't look up the weather for the beach since I'm offline, which is likely similar to Boston's.",
            "I can't check the weather for you since I'm offline, and the beach is lovely this time of year.",
            "I can't check the weather because I'm offline and the beach is lovely this time of year.",
            // Round 12 P2: any statement after a reason; reasons are now a closed list.
            "I can't check the weather because I'm offline and temperatures drop quickly at night.",
            "I can't check the weather because I'm offline and fog rolls in most evenings.",
            "I can't check the weather because I'm offline and it drizzles a lot there.",
            "I can't check the weather because I'm offline and it pours there most afternoons.",
            "I can't check the weather because I'm offline and November nights drop below freezing.",
            "I can't check the weather because I'm offline and you'll want layers.",
            "I can't check the weather since I'm offline and Boston has lovely beaches.",
            "I can't check the weather because fog rolls in most evenings.",
            // Round 13 P2: a statement inside "busy with" or "working on".
            "I can't check the live weather because I'm working with the forecast above that says light rain at times.",
            "I can't look up the weather for the beach since I'm working with Boston's forecast that is likely similar.",
            "I can't check the weather for the beach since I'm working with the city forecast that should be close.",
            "I can't check the weather since I'm working on your trip to Boston where November nights get cold.",
            "I can't check the weather because I'm busy with your beach plans while fog rolls in most evenings.",
            "I can't check the weather because I'm busy with the backup that is almost done.",
        ] {
            for previous in [forecast, ""] {
                XCTAssertFalse(WeatherClaimGuard.refusesWeather(reply), reply)
                let out = WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: home,
                                                ask: "Should I bring an umbrella to the park?", previous: previous)
                XCTAssertNotEqual(out.text, WeatherClaimGuard.canCheck(remembered: home), reply)
            }
        }
        // Round 2 P2 3: a true word about how far a forecast reaches is not
        // a refusal ("Will it rain in May?" went to the model on purpose).
        for reply in [
            "I can't predict the weather that far out; forecasts are only reliable about a week ahead.",
            "I can't tell you the weather in May, forecasts only go about a week out.",
            "I don't have a forecast beyond 16 days.",
            "I won't have the forecast for next month until closer to the date.",
            "I can't get you a weather report for next month, only the next 16 days.",
            "I can't check the weather in May.",
        ] {
            let out = WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: home,
                                            ask: "Will it rain in May?", previous: "")
            XCTAssertNotEqual(out.text, WeatherClaimGuard.canCheck(remembered: home), reply)
        }
        // Round 4 P2 3: a holiday, a date or "yet" lies past the 7-day forecast.
        for (ask, reply) in [
            ("Will it snow on Christmas?", "I can't check the forecast for Christmas yet."),
            ("Will it snow on Thanksgiving?", "I don't have access to the forecast for Thanksgiving yet."),
            ("What's the weather on the 30th?", "I can't get the forecast for that date yet."),
            ("Will it rain on my trip on the 28th?", "I can't check the weather for your trip until it's closer to the date."),
            // Round 5 P2 3: past weather is not something Grux reads either.
            ("Did it rain yesterday?", "I'm sorry, I can't check the weather for yesterday. You might check a weather history site."),
            ("Did it rain yesterday?", "I don't have access to weather information for yesterday. You can check a weather website for past conditions."),
            ("Did it rain last night?", "I can't look up the weather from last night."),
        ] {
            let out = WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: home,
                                            ask: ask, previous: "")
            XCTAssertNotEqual(out.text, WeatherClaimGuard.canCheck(remembered: home), reply)
        }
        // A reading backed by Grux's own forecast stays, refusal check or not.
        let backed = WeatherClaimGuard.vet(reply: "I don't see heavy rain in the forecast, but with a 60% chance I'd bring one.",
                                           route: "local", results: none, remembered: home,
                                           ask: "Should I bring an umbrella to the park?", previous: forecast)
        XCTAssertFalse(backed.replaced, backed.text)
    }

    func testEverythingElseIsLeftAlone() {
        for reply in [
            "Preheat the oven to 350°F and bake for 20 minutes.",
            "It's 72 degrees in here according to the thermostat.",
            "Want me to check the weather for tomorrow?",
            "I can look up the forecast if you tell me your city.",
            "There's a 40% chance the package arrives today.",
            "Rain or shine, the meeting is at 3 PM.",
            "Your CPU is at 85°C under load.",
            "Preheat the oven to 400°F, then add the sun-dried tomatoes.",
        ] {
            let out = WeatherClaimGuard.vet(reply: reply, route: "local", results: none, remembered: nil, ask: "", previous: "")
            XCTAssertFalse(out.replaced, reply)
            XCTAssertEqual(out.text, reply)
        }
    }

    func testAWebReadOrACloudRouteLeavesItAlone() {
        let reply = "It'll be sunny and 75°F tomorrow."
        XCTAssertFalse(WeatherClaimGuard.vet(reply: reply, route: "anthropic", results: none, remembered: nil, ask: "", previous: "").replaced)
        let read: [ActionClaimGuard.ToolResult] = [("research_web", [:], "Sunny, high 75F tomorrow in Boston.")]
        XCTAssertFalse(WeatherClaimGuard.vet(reply: reply, route: "local", results: read, remembered: nil, ask: "", previous: "").replaced)
        let failed: [ActionClaimGuard.ToolResult] = [("research_web", [:], "error: web research unavailable in offline mode.")]
        XCTAssertTrue(WeatherClaimGuard.vet(reply: reply, route: "local", results: failed, remembered: nil, ask: "", previous: "").replaced)
    }

    /// W43-FIX round 3: readings the person gave, or Grux's own forecast just
    /// before, back the reply; `search_web` only opens a browser tab and
    /// reads nothing, so it backs nothing.
    func testReadingsFromTheAskOrTheLastForecastBackTheReply() {
        let lastForecast = "Boston, Massachusetts, tomorrow: light rain, high 52°F, low 40°F, 80% chance of rain."
        let followUp = "No, with a high of 52°F and an 80% chance of rain, wear pants and bring an umbrella."
        XCTAssertFalse(WeatherClaimGuard.vet(reply: followUp, route: "local", results: none, remembered: nil,
                                             ask: "Should I wear shorts tomorrow?", previous: lastForecast).replaced)
        XCTAssertFalse(WeatherClaimGuard.vet(reply: "At 30 degrees with snow, wear a warm coat.", route: "local",
                                             results: none, remembered: nil,
                                             ask: "It's 30 degrees and snowing, what should I wear?", previous: "").replaced)
        XCTAssertFalse(WeatherClaimGuard.vet(reply: "40°F is chilly for a run outside, so wear layers.", route: "local",
                                             results: none, remembered: nil, ask: "Is 40°F too cold to run outside?", previous: "").replaced)
        // One reading nobody gave is enough to replace it.
        XCTAssertTrue(WeatherClaimGuard.vet(reply: "With a high of 52°F and a 90% chance of rain, bring an umbrella.",
                                            route: "local", results: none, remembered: nil,
                                            ask: "Should I wear shorts tomorrow?", previous: lastForecast).replaced)
        // W43-FIX round 4: today's numbers given as tomorrow's are not backed,
        // and a high or a chance of rain is never backed by the question.
        XCTAssertTrue(WeatherClaimGuard.vet(reply: "Tomorrow in Boston: high of 52°F, low 40°F, 80% chance of rain.",
                                            route: "local", results: none, remembered: nil,
                                            ask: "And tomorrow?", previous: "Boston, Massachusetts, now: 48°F. Today: overcast, high 52°F, low 40°F, 80% chance of rain.").replaced)
        XCTAssertTrue(WeatherClaimGuard.vet(reply: "Today's high is 60°F and sunny.", route: "local", results: none,
                                            remembered: nil, ask: "Do I need a jacket if it's below 60?", previous: "").replaced)
        XCTAssertFalse(WeatherClaimGuard.vet(reply: "At around -3 degrees outside, wear a warm coat.", route: "local",
                                             results: none, remembered: nil,
                                             ask: "Should I bike?", previous: "Oslo, Norway, now: -3°C and snow, low -3°C.").replaced)
        let searched: [ActionClaimGuard.ToolResult] = [("search_web", [:], "ok: searched Google for 'weather May'")]
        XCTAssertTrue(WeatherClaimGuard.vet(reply: "Tomorrow: sunny, high of 75°F.", route: "local", results: searched,
                                            remembered: nil, ask: "Will it rain in May?", previous: "").replaced)
    }

    /// In `send()`, after the calendar guard and before the reply is stored.
    func testTheGuardRunsBeforeTheReplyIsStored() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let calendar = try XCTUnwrap(src.range(of: "CalendarClaimGuard.vet(reply: finalText"))
        let weather = try XCTUnwrap(src.range(of: "WeatherClaimGuard.vet(reply: finalText"))
        let stored = try XCTUnwrap(src.range(of: "state.appendChat(ChatMessage(role: .assistant, content: finalText))"))
        XCTAssertTrue(calendar.lowerBound < weather.lowerBound && weather.lowerBound < stored.lowerBound)
    }
}
