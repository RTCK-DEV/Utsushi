import SwiftUI

/// 認識エンジンまわりの設定フォーム。
/// 設定ウインドウの「エンジン」タブと、ファイル未選択の空状態で共用する。
struct EngineSettingsForm: View {
    @EnvironmentObject var model: AppModel

    /// dBFS は音の分野の外では通じない。数値は残しつつ、意味の分かる語を添える。
    /// `Text` に `String` を渡すと verbatim になり翻訳が引かれない。
    /// ここは表示専用なので `LocalizedStringKey` で返す。
    private var silenceLabel: LocalizedStringKey {
        switch model.settings.silenceDBFS {
        case ..<(-55): return "かなり静かでも拾う"
        case ..<(-40): return "標準の音量"
        case ..<(-32): return "やや厳しい"
        default:       return "はっきりした声だけ"
        }
    }

    var body: some View {
        Form {
            Text("""
                 認識エンジンは開始ボタンで選びます。

                 「高速」は OS 内蔵のエンジンを使います。モデルの取得が要らず、\
                 57分の録音を30秒ほどで通しますが、照合も校正も行いません。\
                 固有名詞が崩れやすく、辞書による認識の誘導も効かない点にご注意ください。

                 「標準」は下で選んだ whisper のモデルを使い、\
                 照合タブで指定したエンジンで読み直します。
                 """)
                .font(.caption).foregroundStyle(.secondary)

            Section("「標準」で使うモデル") {
                Picker("モデル", selection: $model.settings.whisperModelID) {
                    ForEach(ModelCatalog.whisperModels) { m in
                        Text("\(m.displayName)（\(ModelCatalog.sizeText(m.approximateBytes))）")
                            .tag(m.id)
                    }
                }
                if let m = ModelCatalog.whisperModels.first(where: { $0.id == model.settings.whisperModelID }) {
                    let installed = ModelCatalog.isInstalled(m)
                    HStack {
                        Text(m.note).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        CapsuleBadge(
                            label: installed ? LocalizedStringKey("導入済み")
                                             : LocalizedStringKey("初回実行時にダウンロード"),
                            color: installed ? .green : .orange)
                    }
                }
            }

            // 以前は自由入力だった。打ち間違えても保存でき、
            // 認識が始まってから初めておかしいと気づく形になっていた。
            Picker("音声の言語", selection: $model.settings.language) {
                Text("日本語").tag("ja")
                Text("英語").tag("en")
                Text("自動判定").tag("auto")
            }
            Text("自動判定は、話者が言語を切り替える収録で外しやすい。分かっているなら指定する方が安定する。")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("取りこぼし疑い区間を自動で再認識する", isOn: $model.settings.autoRepair)

            Section("話者の区別") {
                Toggle(isOn: $model.settings.enableDiarization) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("誰が話したかを区間に付ける（Nemotron 3 Diarization）")
                        Text("""
                             文字起こしと別のモデルで音声を解析し、各発話に話者番号を貼ります。\
                             本文は変わりません。同時に話している箇所にも対応します（最大8人）。
                             """)
                            .font(.caption).foregroundStyle(.secondary)
                        if ModelCatalog.isInstalled(ModelCatalog.diarModel) {
                            Label("導入済み", systemImage: "checkmark.circle.fill")
                                .font(.caption2).foregroundStyle(.green)
                        } else {
                            Label("入れると初回に \(ModelCatalog.sizeText(ModelCatalog.diarModel.approximateBytes)) のダウンロードが走る",
                                  systemImage: "arrow.down.circle")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        if let c = ModelCatalog.diarModel.caveat {
                            Label(c, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        if let a = ModelCatalog.diarModel.attribution {
                            Text(a).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("無音とみなす音の小ささ")
                    Spacer()
                    Text(silenceLabel).font(.caption)
                    Text("(\(Int(model.settings.silenceDBFS)) dBFS)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.settings.silenceDBFS, in: -70...(-25), step: 1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("静かでも拾う").font(.caption2).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("はっきりした声だけ").font(.caption2).foregroundStyle(.secondary)
                }
                Text("""
                     これより小さい音しかない区間は、認識結果が出ていても本文を捨てます。\
                     無音に対して文章を出してしまう「幻聴」を止めるための、主な仕組みです。\
                     右に寄せるほど幻聴は減りますが、小声のやりとりを落としやすくなります。\
                     既定の -45 dBFS 付近から動かす必要は、ふつうありません。
                     """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
    }
}
