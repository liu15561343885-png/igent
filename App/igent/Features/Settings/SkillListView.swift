import CoreKit
import SwiftUI

/// skill 列表：看有哪些、哪些常驻、正文长什么样。
struct SkillListView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var expanded: String?

    var body: some View {
        List {
            Section {
                if env.skillSummaries.isEmpty {
                    ContentUnavailableView(
                        "还没有 skill",
                        systemImage: "text.badge.plus",
                        description: Text("把 SKILL.md 放进 Documents/Skills，或用下面的「重新扫描」。")
                    )
                }

                ForEach(env.skillSummaries) { summary in
                    skillRow(summary)
                }
            } header: {
                Text("已加载 \(env.skillSummaries.count) 个")
            } footer: {
                Text("开关表示**常驻**：每轮都注入。其余 skill 可在对话里手动选，或按 when_to_use 自动匹配。")
            }

            Section {
                LabeledContent("目录", value: "Documents/Skills")
                Button {
                    Task { await env.reloadSkills() }
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
            } footer: {
                Text("在「文件」App 或 Mac 访达里编辑这个目录，改完点重新扫描即可。")
            }
        }
        .navigationTitle("Skill")
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.reloadSkills() }
    }

    private func skillRow(_ summary: SkillSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.name)
                        .font(.callout.monospaced())
                    Text(summary.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: alwaysBinding(summary.name))
                    .labelsHidden()
            }

            if let when = summary.whenToUse, !when.isEmpty {
                Text("触发：\(when)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if expanded == summary.name, let definition = env.skillDefinitions[summary.name] {
                Text(definition.body)
                    .font(.caption.monospaced())
                    .padding(.top, 4)
                    .textSelection(.enabled)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            expanded = expanded == summary.name ? nil : summary.name
        }
    }

    private func alwaysBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { env.alwaysSkillNames.contains(name) },
            set: { isOn in
                var names = env.alwaysSkillNames
                if isOn {
                    names.insert(name)
                } else {
                    names.remove(name)
                }
                env.alwaysSkillNames = names
            }
        )
    }
}
