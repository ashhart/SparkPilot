"""Swift namespace, type and operation rendering."""

from pathlib import Path

from .model import ContractModel, Model, Operation, TypeRef
from .naming import lower_camel, pascal, swift_identifier


def swift_type(type_ref: TypeRef, optional: bool) -> str:
    base = {
        "string": "String",
        "integer": "Int",
        "number": "Double",
        "boolean": "Bool",
        "json": "JSONValue",
        "model": type_ref.name,
        "alias": type_ref.name,
        "enum": type_ref.name,
    }.get(type_ref.kind)
    if type_ref.kind == "array":
        assert type_ref.item is not None
        base = f"[{swift_type(type_ref.item, False)}]"
    if type_ref.kind == "map":
        assert type_ref.item is not None
        base = f"[String: {swift_type(type_ref.item, False)}]"
    assert base is not None
    return base + ("?" if optional or type_ref.nullable else "")



def namespace_lines() -> list[str]:
    lines = [
        "import Foundation",
        "",
        "public enum GeneratedAPI {",
        "    public enum RequestBodyKind: String, Sendable { case none, json, text, binary }",
        "    public enum ResponseContentKind: String, Sendable { case none, json, text, binary, eventStream }",
        "",
        "    public struct Response: Sendable, Equatable {",
        "        public let status: String",
        "        public let mediaType: String?",
        "        public let contentKind: ResponseContentKind",
        "        public let type: String?",
        "    }",
        "",
        "    public struct Parameter: Sendable, Equatable {",
        "        public let name: String",
        "        public let location: String",
        "        public let required: Bool",
        "    }",
        "",
        "    public struct OperationDescriptor: Sendable, Equatable {",
        "        public let id: String",
        "        public let method: String",
        "        public let path: String",
        "        public let requestBodyKind: RequestBodyKind",
        "        public let requestBodyType: String?",
        "        public let parameterType: String?",
        "        public let parameters: [Parameter]",
        "        public let responses: [Response]",
        "    }",
        "",
        "    public enum JSONValue: Codable, Equatable, Sendable {",
        "        case null",
        "        case bool(Bool)",
        "        case signedInteger(Int64)",
        "        case unsignedInteger(UInt64)",
        "        case number(Double)",
        "        case string(String)",
        "        case array([JSONValue])",
        "        case object([String: JSONValue])",
        "",
        "        public init(from decoder: Decoder) throws {",
        "            let value = try decoder.singleValueContainer()",
        "            if value.decodeNil() { self = .null }",
        "            else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }",
        "            else if let decoded = try? value.decode(Int64.self) { self = .signedInteger(decoded) }",
        "            else if let decoded = try? value.decode(UInt64.self) { self = .unsignedInteger(decoded) }",
        "            else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }",
        "            else if let decoded = try? value.decode(String.self) { self = .string(decoded) }",
        "            else if let decoded = try? value.decode([JSONValue].self) { self = .array(decoded) }",
        "            else { self = .object(try value.decode([String: JSONValue].self)) }",
        "        }",
        "",
        "        public func encode(to encoder: Encoder) throws {",
        "            var value = encoder.singleValueContainer()",
        "            switch self {",
        "            case .null: try value.encodeNil()",
        "            case .bool(let decoded): try value.encode(decoded)",
        "            case .signedInteger(let decoded): try value.encode(decoded)",
        "            case .unsignedInteger(let decoded): try value.encode(decoded)",
        "            case .number(let decoded): try value.encode(decoded)",
        "            case .string(let decoded): try value.encode(decoded)",
        "            case .array(let decoded): try value.encode(decoded)",
        "            case .object(let decoded): try value.encode(decoded)",
        "            }",
        "        }",
        "    }",
        "",
        "    struct DynamicCodingKey: CodingKey {",
        "        let stringValue: String",
        "        let intValue: Int? = nil",
        "",
        "        init(_ stringValue: String) { self.stringValue = stringValue }",
        "        init?(stringValue: String) { self.init(stringValue) }",
        "        init?(intValue: Int) { return nil }",
        "    }",
        "",
    ]
    return lines + ["}", ""]


def enum_lines(name: str, values: tuple[str, ...]) -> list[str]:
    lines = []
    lines.append(f"    public enum {name}: String, Codable, Equatable, Sendable {{")
    for value in values:
        case_name = lower_camel(value)
        suffix = f' = "{value}"' if case_name != value else ""
        lines.append(f"        case {swift_identifier(case_name)}{suffix}")
    lines.extend(["    }", ""])
    return lines


def model_lines(model: Model) -> list[str]:
    lines = []
    lines.append(f"    public struct {model.name}: Codable, Equatable, Sendable {{")
    for item in model.fields:
        property_name = lower_camel(item.wire_name)
        lines.append(
            f"        public var {swift_identifier(property_name)}: "
            f"{swift_type(item.type_ref, not item.required)}"
        )
    if model.additional_properties is not None:
        lines.append(
            "        public var additionalProperties: "
            f"[String: {swift_type(model.additional_properties, False)}]"
        )
    if not model.fields:
        if model.additional_properties is None:
            lines.append("        public init() {}")
        else:
            lines.append(
                "        public init(additionalProperties: "
                f"[String: {swift_type(model.additional_properties, False)}] = [:]) {{"
            )
            lines.append("            self.additionalProperties = additionalProperties")
            lines.append("        }")
    else:
        lines.append("")
        lines.append("        public init(")
        for index, item in enumerate(model.fields):
            property_name = lower_camel(item.wire_name)
            default = " = nil" if not item.required else ""
            comma = "," if index < len(model.fields) - 1 or model.additional_properties else ""
            lines.append(
                f"            {swift_identifier(property_name)}: "
                f"{swift_type(item.type_ref, not item.required)}{default}{comma}"
            )
        if model.additional_properties is not None:
            lines.append(
                "            additionalProperties: "
                f"[String: {swift_type(model.additional_properties, False)}] = [:]"
            )
        lines.append("        ) {")
        for item in model.fields:
            property_name = lower_camel(item.wire_name)
            escaped = swift_identifier(property_name)
            lines.append(f"            self.{escaped} = {escaped}")
        if model.additional_properties is not None:
            lines.append("            self.additionalProperties = additionalProperties")
        lines.append("        }")
        if model.additional_properties is not None:
            known_keys = ", ".join(f'"{item.wire_name}"' for item in model.fields)
            lines.extend(
                [
                    "",
                    "        public init(from decoder: Decoder) throws {",
                    "            let container = try decoder.container(keyedBy: DynamicCodingKey.self)",
                ]
            )
            for item in model.fields:
                property_name = lower_camel(item.wire_name)
                if item.required:
                    decoded_type = swift_type(item.type_ref, False)
                    decode_method = "decode"
                else:
                    nonnullable = TypeRef(
                        item.type_ref.kind,
                        item.type_ref.name,
                        item.type_ref.item,
                        False,
                    )
                    decoded_type = swift_type(nonnullable, False)
                    decode_method = "decodeIfPresent"
                lines.append(
                    f"            self.{swift_identifier(property_name)} = "
                    f"try container.{decode_method}("
                    f'{decoded_type}.self, forKey: DynamicCodingKey("{item.wire_name}"))'
                )
            lines.extend(
                [
                    f"            let knownKeys: Set<String> = [{known_keys}]",
                    "            self.additionalProperties = try Dictionary(uniqueKeysWithValues:",
                    "                container.allKeys.filter { !knownKeys.contains($0.stringValue) }.map { key in",
                    "                    (key.stringValue, try container.decode(",
                    f"                        {swift_type(model.additional_properties, False)}.self, forKey: key))",
                    "                }",
                    "            )",
                    "        }",
                    "",
                    "        public func encode(to encoder: Encoder) throws {",
                    "            var container = encoder.container(keyedBy: DynamicCodingKey.self)",
                ]
            )
            for item in model.fields:
                property_name = lower_camel(item.wire_name)
                encode_method = (
                    "encodeIfPresent"
                    if not item.required or item.type_ref.nullable
                    else "encode"
                )
                lines.append(
                    f"            try container.{encode_method}("
                    f"{swift_identifier(property_name)}, "
                    f'forKey: DynamicCodingKey("{item.wire_name}"))'
                )
            lines.extend(
                [
                    f"            let knownKeys: Set<String> = [{known_keys}]",
                    "            for (key, value) in additionalProperties where !knownKeys.contains(key) {",
                    "                try container.encode(value, forKey: DynamicCodingKey(key))",
                    "            }",
                    "        }",
                ]
            )
        else:
            renamed = [
                item
                for item in model.fields
                if lower_camel(item.wire_name) != item.wire_name
            ]
            if not renamed:
                lines.append("    }")
                lines.append("")
                return lines
            lines.append("")
            lines.append("        private enum CodingKeys: String, CodingKey {")
            for item in model.fields:
                property_name = lower_camel(item.wire_name)
                suffix = f' = "{item.wire_name}"' if property_name != item.wire_name else ""
                lines.append(f"            case {swift_identifier(property_name)}{suffix}")
            lines.append("        }")
    lines.append("    }")
    lines.append("")
    return lines


def operation_lines(operation: Operation) -> list[str]:
    lines = []
    request_type = f'"{operation.request_type}"' if operation.request_type else "nil"
    parameter_type = f'"{operation.parameter_type}"' if operation.parameter_type else "nil"
    lines.extend(
        [
            "        OperationDescriptor(",
            f'            id: "{operation.operation_id}",',
            f'            method: "{operation.method}",',
            f'            path: "{operation.path}",',
            f"            requestBodyKind: .{operation.request_kind},",
            f"            requestBodyType: {request_type},",
            f"            parameterType: {parameter_type},",
            "            parameters: [",
        ]
    )
    for parameter in operation.parameters:
        required = "true" if parameter.required else "false"
        lines.append(
            f'                Parameter(name: "{parameter.name}", '
            f'location: "{parameter.location}", required: {required}),'
        )
    lines.extend(
        [
            "            ],",
            "            responses: [",
        ]
    )
    for response in operation.responses:
        type_name = f'"{response.type_name}"' if response.type_name else "nil"
        media_type = f'"{response.media_type}"' if response.media_type else "nil"
        lines.append(
            f'                Response(status: "{response.status}", '
            f"mediaType: {media_type}, contentKind: .{response.content_kind}, "
            f"type: {type_name}),"
        )
    lines.extend(["            ]", "        ),"])
    return lines


def swift_file(digest: str, lines: list[str], *, namespace: bool = False) -> str:
    header = [
        "// swift-format-ignore-file",
        "",
        f"// Generated by tools/generate_openapi_clients.py; OpenAPI SHA-256: {digest}. Do not edit.",
    ]
    if namespace:
        return "\n".join(header + lines)
    return "\n".join(header + ["import Foundation", "", "extension GeneratedAPI {"] + lines + ["}", ""])


def render_swift_files(contract: ContractModel, digest: str) -> dict[str, str]:
    files = {"APIContract.generated.swift": swift_file(digest, namespace_lines(), namespace=True)}
    for name, values in contract.enums.items():
        files[f"Enums/{name}.generated.swift"] = swift_file(digest, enum_lines(name, values))
    for name, type_ref in contract.aliases.items():
        files[f"Aliases/{name}.generated.swift"] = swift_file(
            digest, [f"    public typealias {name} = {swift_type(type_ref, False)}"]
        )
    for model in contract.models.values():
        files[f"Models/{model.name}.generated.swift"] = swift_file(digest, model_lines(model))
    table = ["    public static let operations: [OperationDescriptor] = ["]
    for operation in contract.operations:
        name = "operation" + pascal(operation.operation_id)
        body = operation_lines(operation)
        body[0] = f"    static let {name} = OperationDescriptor("
        body[-1] = "        )"
        files[f"Operations/{pascal(operation.operation_id)}.Operation.generated.swift"] = swift_file(digest, body)
        table.append(f"        {name},")
    files["Operations.generated.swift"] = swift_file(digest, table + ["    ]"])
    expected_count = 2 + len(contract.enums) + len(contract.aliases) + len(contract.models) + len(contract.operations)
    basenames = {Path(path).name.casefold() for path in files}
    if len(files) != expected_count or len(basenames) != len(files):
        raise ValueError("Generated Swift declarations have colliding output filenames")
    return files


def render_swift(contract: ContractModel, digest: str) -> str:
    return "\n".join(render_swift_files(contract, digest).values())
