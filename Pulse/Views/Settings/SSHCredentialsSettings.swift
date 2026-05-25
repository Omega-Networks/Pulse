//
//  SSHCredentialsSettings.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Pulse
//  The Platform for Unified Leadership in Smart Environments.
//
//  This program is distributed to enable communities to build and maintain their own
//  digital sovereignty through local control of critical infrastructure data.
//
//  By open sourcing Pulse, we create a circular economy where contributors can both build
//  upon and benefit from the platform, ensuring that value flows back to communities rather
//  than being extracted by external entities. This aligns with our commitment to intergenerational
//  prosperity through collaborative stewardship of public infrastructure.
//
//  This program is free software: communities can deploy it for sovereignty, academia can
//  extend it for research, and industry can integrate it for resilience — all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import CryptoKit
import OSLog
import SwiftData
import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Settings pane for managing SSH credentials.
///
/// Two creation paths:
///
/// - **Secure Enclave (default)**: generates a non-exportable ECDSA P-256 key inside
///   the Enclave. Biometric or device passcode is required for every signature.
/// - **Legacy (portable key)**: imports a PEM private key (Ed25519, ECDSA, RSA) into
///   the Keychain. Guarded behind an explicit "Legacy" second screen so it's never
///   accidentally chosen.
///
/// The "Legacy" labelling and the two-step import sheet are structural enforcements
/// of ADR 0001 §1: the unsafe path is unavailable by default, not just discouraged.
struct SSHCredentialsSettings: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SSHCredential.label) private var credentials: [SSHCredential]

    @State private var creatingSE = false
    @State private var importingLegacy = false
    @State private var pendingDelete: SSHCredential?
    @State private var errorMessage: String?
    /// Tracks the most recently copied credential so the row's copy button can show
    /// transient "Copied" feedback. Cleared after 1.5 seconds.
    @State private var recentlyCopied: UUID?
    #if DEBUG
    /// Holds the formatted output of the debug "Inspect key attributes" action.
    /// Drives the inspection alert; non-nil when a result is awaiting display.
    @State private var inspectResult: String?
    #endif

    private let logger = Logger(subsystem: "pulse", category: "ssh.credentials")

    var body: some View {
        Form {
            credentialsSection
            createSection
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
        .sheet(isPresented: $creatingSE) {
            CreateSecureEnclaveCredentialSheet { newCred in
                modelContext.insert(newCred)
                logger.info("Created SE credential \(newCred.id): \(newCred.label)")
            }
        }
        .sheet(isPresented: $importingLegacy) {
            ImportLegacyCredentialSheet { newCred in
                modelContext.insert(newCred)
                logger.info("Imported legacy credential \(newCred.id): \(newCred.label)")
            }
        }
        .confirmationDialog(
            "Delete this credential?",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { cred in
            Button("Delete \(cred.label)", role: .destructive) {
                deleteCredential(cred)
            }
        } message: { cred in
            if cred.tier == .secureEnclave {
                Text("This removes the Secure Enclave key. It cannot be recovered or re-issued. Generate a new credential and re-enrol the public key on every device that trusted this one.")
            } else {
                Text("Removes the private key PEM and any passphrase from the Keychain. The legacy key is gone unless you have a backup.")
            }
        }
        .alert("Couldn't update credentials", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        #if DEBUG
        .alert("Key attributes", isPresented: inspectAlertBinding) {
            Button("OK", role: .cancel) { inspectResult = nil }
        } message: {
            Text(inspectResult ?? "")
        }
        #endif
    }

    // MARK: - Sections

    private var credentialsSection: some View {
        Section(header: header("SSH Credentials")) {
            if credentials.isEmpty {
                Text("No credentials yet. Create a Secure Enclave-backed credential to get started.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(credentials) { cred in
                    credentialRow(cred)
                }
            }
        }
    }

    private var createSection: some View {
        Section(header: header("Add Credential")) {
            Button {
                creatingSE = true
            } label: {
                Label("Create Secure Enclave credential…", systemImage: "lock.shield")
            }
            Button {
                importingLegacy = true
            } label: {
                Label("Import legacy key (PEM)…", systemImage: "doc.badge.ellipsis")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func credentialRow(_ cred: SSHCredential) -> some View {
        HStack(alignment: .top, spacing: 12) {
            tierBadge(cred.tier)
            VStack(alignment: .leading, spacing: 4) {
                Text(cred.label)
                    .font(.body.weight(.medium))
                Text(fingerprintDisplay(of: cred))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                certificateInfo(for: cred)
                if cred.recordSessions {
                    Label("Sessions recorded", systemImage: "record.circle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            copyPublicKeyButton(for: cred)
            Button {
                pendingDelete = cred
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(cred.label)")
        }
        .padding(.vertical, 4)
        #if DEBUG
        .contextMenu {
            Button("Inspect key attributes") { inspect(cred) }
        }
        #endif
    }

    /// Copy-to-clipboard button for the credential's OpenSSH-format public key
    /// (the `authorized_keys` line). Rendered whenever a public key is
    /// available, regardless of tier. Secure Enclave credentials always have
    /// one; portable credentials get one derived at import time when the PEM
    /// format permits, and otherwise wait for the auth delegate's first-use
    /// backfill. The disabled-button state would be ambiguous, so the button
    /// is hidden until there's something to copy. The row's caption alongside
    /// the fingerprint explains the state in the meantime.
    @ViewBuilder
    private func copyPublicKeyButton(for cred: SSHCredential) -> some View {
        if !cred.publicKey.isEmpty {
            let isCopied = recentlyCopied == cred.id
            Button {
                copyPublicKey(for: cred)
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(isCopied ? .green : .primary)
            }
            .buttonStyle(.borderless)
            .help("Copy the OpenSSH public key (authorized_keys line) to the clipboard")
            .accessibilityLabel("Copy public key for \(cred.label)")
        }
    }

    /// Renders the certificate principals and expiry below the fingerprint when the
    /// credential carries a CA-signed certificate. Parsing happens inline on each
    /// render: the cert blob is small (single OpenSSH line) and the credentials list
    /// is short, so caching would be premature. On parse failure the row shows a
    /// generic warning rather than crashing the view; the operator action is to
    /// re-import the cert.
    @ViewBuilder
    private func certificateInfo(for cred: SSHCredential) -> some View {
        if let blob = cred.certificate {
            if let meta = try? SSHCertificateManager.metadata(for: blob) {
                let principals = meta.principals.isEmpty
                    ? "any principal"
                    : meta.principals.joined(separator: ", ")
                let expired = !SSHCertificateManager.isValid(meta)
                HStack(spacing: 6) {
                    Image(systemName: expired ? "exclamationmark.seal" : "seal")
                        .foregroundStyle(expired ? .red : .green)
                    Text("Cert: \(principals) · expires \(meta.validBefore.formatted(date: .abbreviated, time: .omitted))")
                        .foregroundStyle(expired ? .red : .secondary)
                }
                .font(.caption2)
            } else {
                Label("Cert: parse failed", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func tierBadge(_ tier: SSHCredentialTier) -> some View {
        Group {
            switch tier {
            case .secureEnclave:
                Label("Secure Enclave", systemImage: "lock.shield.fill")
                    .foregroundStyle(.green)
            case .portable:
                Label("Legacy", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption.weight(.semibold))
        .labelStyle(.titleAndIcon)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.title3)
            .fontWeight(.bold)
    }

    // MARK: - Copy public key

    /// Copies the OpenSSH `authorized_keys` line for the credential to the
    /// system clipboard, then flips the row's button icon to a checkmark for
    /// 1.5 s so the operator sees the action took effect.
    ///
    /// For Secure Enclave credentials the line is rendered by
    /// `SecureEnclaveKeyManager.authorizedKeysLine` (which reads only public
    /// material and does not prompt for biometric). For portable credentials
    /// the line is rendered directly from `cred.publicKey` — the OpenSSH
    /// wire-format bytes derived at import time. Falls through quietly when
    /// `publicKey` is empty so the button-gate caller is the single source of
    /// truth on visibility.
    private func copyPublicKey(for cred: SSHCredential) {
        let line: String
        do {
            switch cred.tier {
            case .secureEnclave:
                line = try SecureEnclaveKeyManager.authorizedKeysLine(
                    for: cred.id,
                    comment: cred.label
                )
            case .portable:
                guard let portableLine = authorizedKeysLine(
                    fromOpenSSHWire: cred.publicKey,
                    comment: cred.label
                ) else {
                    return
                }
                line = portableLine
            }
        } catch {
            errorMessage = "Couldn't copy public key for \(cred.label): \(error)"
            logger.error("Public key copy failed for \(cred.id): \(error)")
            return
        }

        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = line
        #endif
        recentlyCopied = cred.id
        let id = cred.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            if recentlyCopied == id {
                recentlyCopied = nil
            }
        }
        logger.info("Copied public key for credential \(cred.id)")
    }

    /// Renders an `authorized_keys` line from an OpenSSH wire-format public
    /// key. The first length-prefixed SSH string in the wire bytes is the
    /// algorithm identifier; the full wire bytes are the base64 payload.
    /// Returns nil if the buffer is shorter than the four-byte length prefix
    /// or the algorithm string runs past the buffer.
    private func authorizedKeysLine(fromOpenSSHWire wire: Data, comment: String) -> String? {
        let bytes = [UInt8](wire)
        guard bytes.count >= 4 else { return nil }
        let length =
            (Int(bytes[0]) << 24)
            | (Int(bytes[1]) << 16)
            | (Int(bytes[2]) << 8)
            | Int(bytes[3])
        guard 4 + length <= bytes.count else { return nil }
        let algoBytes = Data(bytes[4..<(4 + length)])
        guard let algo = String(data: algoBytes, encoding: .ascii) else { return nil }
        let base64 = wire.base64EncodedString()
        let trimmedComment = comment.trimmingCharacters(in: .whitespaces)
        if trimmedComment.isEmpty {
            return "\(algo) \(base64)"
        }
        return "\(algo) \(base64) \(trimmedComment)"
    }

    // MARK: - Delete

    /// Deletes a credential in the correct order: secret material first, then the
    /// SwiftData record. If the secret cleanup fails the model is left alone so
    /// the operator can retry. An orphaned SE key or PEM with no metadata is a
    /// worse end state than a row the user can delete again.
    private func deleteCredential(_ cred: SSHCredential) {
        let id = cred.id
        let tier = cred.tier
        let label = cred.label

        Task {
            do {
                try await deleteSecretMaterial(for: id, tier: tier)
            } catch {
                await MainActor.run {
                    errorMessage = "Couldn't delete \(label)'s secret material: \(error). The credential record is unchanged. Try again or check Keychain Access."
                }
                logger.error("Aborting credential delete for \(id) (\(tier.rawValue)): \(error)")
                return
            }

            // Secret is gone. Remove the row and clear any Device pointers in the
            // same transaction. Explicit save so the cleanup is durable even if
            // SwiftData's autosave hasn't fired yet.
            await MainActor.run {
                modelContext.delete(cred)
                let devices = (try? modelContext.fetch(
                    FetchDescriptor<Device>(
                        predicate: #Predicate { $0.defaultCredentialID == id }
                    )
                )) ?? []
                for device in devices {
                    device.defaultCredentialID = nil
                }
                do {
                    try modelContext.save()
                } catch {
                    errorMessage = "Device pointer cleanup save failed: \(error). The secret and credential metadata are already gone. Re-open Settings to verify state."
                }
            }
            logger.info("Deleted credential \(id) (\(tier.rawValue))")
        }
    }

    private func deleteSecretMaterial(for credentialID: UUID, tier: SSHCredentialTier) async throws {
        switch tier {
        case .secureEnclave:
            try SecureEnclaveKeyManager.deleteKey(for: credentialID)
        case .portable:
            let ok = await Configuration.shared.deleteSSHMaterial(for: credentialID)
            guard ok else { throw SSHCredentialDeletionError.keychainCleanupFailed }
        }
    }

    private enum SSHCredentialDeletionError: Error, CustomStringConvertible {
        case keychainCleanupFailed
        var description: String {
            "One or more Keychain material entries refused to delete."
        }
    }

    // MARK: - Bindings

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    #if DEBUG
    private var inspectAlertBinding: Binding<Bool> {
        Binding(
            get: { inspectResult != nil },
            set: { if !$0 { inspectResult = nil } }
        )
    }

    // MARK: - Debug inspection

    /// Reads the Keychain attributes for an SE credential and renders them into the
    /// inspection alert. Lets the operator confirm at runtime that keys land in the
    /// expected access group, are on the data-protection keychain, aren't
    /// synchronisable, and use the correct accessibility class.
    ///
    /// Compiled out of Release builds.
    private func inspect(_ cred: SSHCredential) {
        guard cred.tier == .secureEnclave else {
            inspectResult = "Legacy credentials don't have an SE record to inspect."
            return
        }
        do {
            let attributes = try SecureEnclaveKeyManager.inspect(cred.id)
            inspectResult = """
            Credential: \(cred.label)
            Access group: \(attributes.accessGroup)
            Token ID: \(attributes.tokenID)
            Synchronizable: \(attributes.synchronizable)
            Access control: \(attributes.accessControl)
            """
            logger.debug("Inspection for \(cred.id): \(inspectResult ?? "")")
        } catch {
            inspectResult = "Inspection failed: \(error)"
        }
    }
    #endif

    // MARK: - Fingerprint

    /// Returns either the SHA256 OpenSSH fingerprint of the credential's public key,
    /// or a tier-appropriate placeholder when the public key has not yet been
    /// derived. Portable credentials store only the PEM private material at import
    /// time; the OpenSSH-format public key is filled in once the signer parses
    /// the PEM, which happens later in the SSH client integration.
    private func fingerprintDisplay(of cred: SSHCredential) -> String {
        guard !cred.publicKey.isEmpty else {
            switch cred.tier {
            case .secureEnclave:
                return "no public key"
            case .portable:
                return "PEM stored — public key derived on first use"
            }
        }
        let hash = SHA256.hash(data: cred.publicKey)
        let base64 = Data(hash)
            .base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64)"
    }
}

// MARK: - Create Secure Enclave Credential Sheet

private struct CreateSecureEnclaveCredentialSheet: View {

    let onCreate: (SSHCredential) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label: String = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Secure Enclave credential")
                .font(.title2).fontWeight(.semibold)
            Text("The private key is generated inside this device's Secure Enclave and cannot be exported. Every signing operation prompts for biometric or device passcode.")
                .foregroundStyle(.secondary)

            Form {
                TextField("Label", text: $label, prompt: Text("Core switches"))
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.columns)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await generate() }
                } label: {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Generate")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || isGenerating)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
    }

    private func generate() async {
        isGenerating = true
        defer { isGenerating = false }
        errorMessage = nil
        let credentialID = UUID()
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        do {
            let wire = try SecureEnclaveKeyManager.generateKey(
                for: credentialID,
                label: "Pulse SSH credential: \(trimmedLabel)"
            )
            let credential = SSHCredential(
                id: credentialID,
                label: trimmedLabel,
                tier: .secureEnclave,
                publicKey: wire
            )
            onCreate(credential)
            dismiss()
        } catch {
            errorMessage = "\(error)"
        }
    }
}

// MARK: - Import Legacy Credential Sheet

private struct ImportLegacyCredentialSheet: View {

    let onCreate: (SSHCredential) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .warning
    @State private var label: String = ""
    // Secret-material state is held as `Data` so the persistent buffer can be
    // explicitly zeroed on dismissal via `Data.resetBytes(in:)`. The
    // `pemDisplay` / `passphraseDisplay` bindings below adapt these to the
    // `Binding<String>` that SwiftUI's `TextEditor` and `SecureField` require.
    //
    // **What this delivers:** the persistent plaintext window closes on
    // dismissal — once the sheet goes away there is no Pulse-owned plaintext
    // residue waiting for the garbage collector.
    //
    // **What this does not deliver:** zero-cost zeroing of every transient
    // plaintext copy. SwiftUI's `TextField`/`SecureField` bind to `String`,
    // and the underlying AppKit/UIKit text input maintains its own buffer we
    // cannot reach. Each keystroke materialises a transient `String` via the
    // binding shim; those instances are dropped to the runtime allocator
    // without being zeroed. The improvement is bounded but real.
    @State private var pem: Data = Data()
    @State private var passphrase: Data = Data()
    @State private var importedKey: SSHKeyImporter.ImportedSSHKey?
    @State private var errorMessage: String?

    private enum Step {
        case warning
        case form
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case .warning:
                warningStep
            case .form:
                formStep
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
        .onDisappear {
            // Zero the persistent buffers regardless of whether the sheet
            // dismissed via Cancel, successful commit, or window close.
            if !pem.isEmpty {
                pem.resetBytes(in: 0..<pem.count)
            }
            if !passphrase.isEmpty {
                passphrase.resetBytes(in: 0..<passphrase.count)
            }
        }
    }

    /// `Binding<String>` adapter for the PEM TextEditor. Converts on read
    /// (`String(data: utf8)`) and re-encodes on write (`Data(.utf8)`). Each
    /// keystroke materialises an ephemeral `String` we cannot zero; the
    /// improvement vs. holding the persistent buffer as `String` is that the
    /// dismissal path resets the persistent buffer to zero, eliminating the
    /// post-dismissal plaintext residue.
    private var pemDisplay: Binding<String> {
        Binding(
            get: { String(data: pem, encoding: .utf8) ?? "" },
            set: { newValue in pem = Data(newValue.utf8) }
        )
    }

    private var passphraseDisplay: Binding<String> {
        Binding(
            get: { String(data: passphrase, encoding: .utf8) ?? "" },
            set: { newValue in passphrase = Data(newValue.utf8) }
        )
    }

    // MARK: Step 1 (gated warning)

    private var warningStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Legacy (portable key)", systemImage: "exclamationmark.shield.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.orange)

            Text("Portable keys live in the Keychain as exportable bytes. They survive device loss, factory reset, and copy-paste, which is also why they're riskier. The default path (Secure Enclave) keeps the private half on this device only.")
                .foregroundStyle(.secondary)

            Text("Only continue if you need to import an existing key that a device or vendor already trusts.")
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue with legacy import") {
                    step = .form
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Step 2 (paste and validate)

    private var formStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import legacy key")
                .font(.title2).fontWeight(.semibold)

            TextField("Label", text: $label, prompt: Text("Vendor default"))
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Private key (PEM)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: pemDisplay)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }

            if let importedKey, importedKey.isEncrypted {
                SecureField("Passphrase", text: passphraseDisplay)
                    .textFieldStyle(.roundedBorder)
            }

            if let importedKey {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Detected: \(importedKey.algorithm.displayName) (\(importedKey.pemKind.rawValue))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if importedKey.isEncrypted {
                        Text("Key is encrypted. Passphrase required.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Validate") {
                    validate()
                }
                .disabled(pem.isEmpty)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Import") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
    }

    private var canImport: Bool {
        guard let importedKey else { return false }
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if importedKey.isEncrypted && passphrase.isEmpty { return false }
        return true
    }

    private func validate() {
        errorMessage = nil
        // Classifier still operates on a String; the conversion happens at the
        // call boundary so the persistent state can stay as Data.
        let pemString = String(data: pem, encoding: .utf8) ?? ""
        do {
            importedKey = try SSHKeyImporter.validate(pemString)
        } catch {
            importedKey = nil
            errorMessage = "\(error)"
        }
    }

    private func commit() {
        guard let importedKey else { return }
        let credentialID = UUID()
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        // Capture the Data-typed payloads up front so the Task body doesn't
        // capture `self`'s @State (which would extend the plaintext window
        // past the onDisappear zero).
        let pemData = importedKey.normalisedPEMData
        let passphraseData = passphrase
        Task {
            let config = await Configuration.shared
            let ok = await config.setSSHPrivateKeyPEM(pemData, for: credentialID)
            guard ok else {
                await MainActor.run { errorMessage = "Couldn't store the PEM in the Keychain." }
                return
            }
            if importedKey.isEncrypted {
                _ = await config.setSSHPassphrase(passphraseData, for: credentialID)
            }

            // Derive the OpenSSH wire-format public key from the imported PEM
            // when the format supports it (OpenSSH new-format covers Ed25519,
            // ECDSA, and RSA regardless of cipher; PKCS#1 / PKCS#8 cover
            // unencrypted RSA). For encrypted PKCS#1/PKCS#8 and traditional
            // EC PEMs, derivation defers to the auth delegate's first-use
            // backfill: the credential stores `Data()` and the fingerprint
            // display shows the "derived on first use" caption until then.
            let derivedPublicKey: Data
            do {
                derivedPublicKey = try SSHKeyImporter.derivePublicKey(from: importedKey)
            } catch {
                Logger(subsystem: "pulse", category: "ssh.credentials").info(
                    "Deferred public-key derivation for credential \(credentialID): \(String(describing: error))"
                )
                derivedPublicKey = Data()
            }

            let credential = SSHCredential(
                id: credentialID,
                label: trimmedLabel,
                tier: .portable,
                publicKey: derivedPublicKey
            )
            await MainActor.run {
                onCreate(credential)
                dismiss()
            }
        }
    }
}
