import Foundation
import SparkCore
import SwiftUI

struct RetailAdministratorCredentials: View {
    @Binding var administratorUsername: String
    @Binding var administratorPassword: String
    @Binding var isAdministratorPasswordVisible: Bool
    @FocusState private var focusedCredentialField: AdministratorCredentialField?

    private enum AdministratorCredentialField: Hashable {
        case username
        case password
    }

    var body: some View {
        VStack(spacing: 14) {
            administratorCredentialInput(
                String(localized: "Username"),
                systemImage: "person.fill",
                focus: .username
            ) {
                TextField(
                    "Spark account username",
                    text: $administratorUsername
                )
                .textContentType(.username)
                .focused($focusedCredentialField, equals: .username)
                .submitLabel(.next)
                .onSubmit { focusedCredentialField = .password }
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
            }

            administratorCredentialInput(
                String(localized: "Password"),
                systemImage: "lock.fill",
                focus: .password
            ) {
                HStack(spacing: 10) {
                    if isAdministratorPasswordVisible {
                        TextField(
                            "Spark account password",
                            text: $administratorPassword
                        )
                        .textContentType(.password)
                        .focused($focusedCredentialField, equals: .password)
                        .submitLabel(.done)
                    } else {
                        SecureField(
                            "Spark account password",
                            text: $administratorPassword
                        )
                        .textContentType(.password)
                        .focused($focusedCredentialField, equals: .password)
                        .submitLabel(.done)
                    }

                    Button {
                        isAdministratorPasswordVisible.toggle()
                        focusedCredentialField = .password
                    } label: {
                        Image(
                            systemName: isAdministratorPasswordVisible
                                ? "eye.slash" : "eye"
                        )
                        .frame(width: 28, height: 44)
                        .contentShape(Rectangle())
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        isAdministratorPasswordVisible
                            ? "Hide password" : "Show password"
                    )
                }
            }
        }
        .frame(maxWidth: 440)
    }

    private func administratorCredentialInput<Content: View>(
        _ title: String,
        systemImage: String,
        focus: AdministratorCredentialField,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isFocused = focusedCredentialField == focus

        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(isFocused ? Color.accentColor : Color.secondary)
                content()
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(
                .quaternary.opacity(0.45),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isFocused ? Color.accentColor : Color.secondary.opacity(0.18),
                        lineWidth: isFocused ? 2 : 1
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                focusedCredentialField = focus
            }
        )
    }

}
