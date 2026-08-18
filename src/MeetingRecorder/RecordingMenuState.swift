struct RecordingMenuState {
    let recordTitle: String
    let recordEnabled: Bool
    let transcribeLastEnabled: Bool
    let transcribeAnyEnabled: Bool

    static func make(
        isRecording: Bool,
        isFinishing: Bool,
        isTranscribing: Bool,
        micAvailable: Bool,
        sourceExists: Bool
    ) -> RecordingMenuState {
        if isRecording {
            return RecordingMenuState(
                recordTitle: "Stop and Save Recording",
                recordEnabled: !isTranscribing,
                transcribeLastEnabled: false,
                transcribeAnyEnabled: false
            )
        }

        if isFinishing {
            return RecordingMenuState(
                recordTitle: "Finishing M4A…",
                recordEnabled: false,
                transcribeLastEnabled: false,
                transcribeAnyEnabled: false
            )
        }

        let canUseActions = !isTranscribing
        return RecordingMenuState(
            recordTitle: "Start Meeting Recording…",
            recordEnabled: canUseActions && micAvailable,
            transcribeLastEnabled: canUseActions && sourceExists,
            transcribeAnyEnabled: canUseActions
        )
    }
}
