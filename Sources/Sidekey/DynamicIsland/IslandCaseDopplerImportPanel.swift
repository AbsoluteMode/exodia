import SwiftUI

struct IslandCaseDopplerImportPanel: View {
    @ObservedObject var viewModel: CaseViewModel
    var onBack: () -> Void
    @State private var task: Task<Void, Never>?
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("‹ Ключи", action: onBack)
                    .disabled(viewModel.isImporting)
                Spacer()
                Text("Импорт из Doppler").fontWeight(.semibold)
            }
            Text("Все доступные проекты и окружения")
                .font(.system(size: 13, weight: .semibold))
            Text("Каждое окружение станет отдельной группой: например, my-app / dev и my-app / prd. Используется ваш вход в Doppler CLI на этом Mac.")
            Text("Секреты сохранятся в зашифрованном Case. Существующие ключи не заменяются. Doppler останется без изменений.")
            if let message {
                Text(message)
                    .foregroundStyle(failed ? Color.red : Color.white)
                    .accessibilityIdentifier("case.doppler.result")
            }
            Spacer(minLength: 0)
            if viewModel.isImporting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Читаю проекты и ключи…")
                    Spacer(minLength: 0)
                    Button("Отмена") { task?.cancel() }
                }
            } else {
                Button(message != nil && !failed ? "Проверить ещё раз" : "Перенести все секреты", action: start)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.white.opacity(0.14)))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("case.doppler.start")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.9))
        .buttonStyle(.plain)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { task?.cancel() }
    }

    private func start() {
        guard task == nil, !viewModel.isImporting else { return }
        message = nil
        failed = false
        task = Task { @MainActor in
            do {
                let result = try await viewModel.importFromDoppler()
                message = result.message
            } catch is CancellationError {
                message = "Импорт отменён. Case не изменён."
            } catch {
                failed = true
                message = (error as? CaseDopplerImportError)?.userMessage ?? "Не удалось сохранить импорт. Case не изменён."
            }
            task = nil
        }
    }
}
