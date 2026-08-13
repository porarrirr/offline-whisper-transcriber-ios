# Offline Whisper Transcriber for iOS

English | [日本語](README.ja.md)

An iPhone app for transcribing recordings and imported audio with Whisper running on the device. After the selected model is downloaded, transcription can be completed without sending audio to a transcription server.

## Highlights

- On-device Whisper transcription powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
- Record audio and transcribe it after recording
- Import M4A, WAV, MP3, MP4, and MOV files
- Support for Japanese and roughly 20 languages
- Voice activity detection to skip silence
- Searchable history, favorites, and Siri Shortcuts
- Multiple Whisper model sizes for balancing download size, speed, and accuracy

## Privacy

Transcription runs locally after the model download. Audio does not need to be uploaded to a project-operated transcription service. Model downloads and any external files you choose to import still use the corresponding network or file providers.

## Requirements

- iOS 17 or later; a physical device is recommended for Whisper
- macOS 14 or later and Xcode 15 or later for development
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build

```bash
git clone --recursive https://github.com/porarrirr/offline-whisper-transcriber-ios.git
cd offline-whisper-transcriber-ios/WhisperTranscriptionApp
cd whisper.cpp && ./build-xcframework.sh && cd ..
cp -R whisper.cpp/build-apple/whisper.xcframework Frameworks/
./Scripts/sign-whisper-xcframework.sh
xcodegen generate
open WhisperTranscriptionApp.xcodeproj
```

More detailed setup instructions are available in [`WhisperTranscriptionApp/README.md`](WhisperTranscriptionApp/README.md).

## License

The app source is provided under the [MIT License](LICENSE). Submodules and third-party dependencies remain subject to their own licenses.
