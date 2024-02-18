import AVFoundation


print(Locale.current.languageCode)

let utterance = AVSpeechUtterance(string: "Sleep Timer extended")
//utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
//utterance.rate = 0.1

let synthesizer = AVSpeechSynthesizer()
synthesizer.speak(utterance)
