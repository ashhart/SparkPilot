"""Rust type modules with stable public re-exports."""

from .model import ContractModel, Model, Operation, TypeRef
from .naming import pascal, rust_name, screaming_snake, snake


def rust_type(type_ref: TypeRef, optional: bool) -> str:
    base = {
        "string": "String",
        "integer": "i64",
        "number": "f64",
        "boolean": "bool",
        "json": "serde_json::Value",
        "model": type_ref.name,
        "alias": type_ref.name,
        "enum": type_ref.name,
    }.get(type_ref.kind)
    if type_ref.kind == "array":
        assert type_ref.item is not None
        base = f"Vec<{rust_type(type_ref.item, False)}>"
    if type_ref.kind == "map":
        assert type_ref.item is not None
        base = f"std::collections::BTreeMap<String, {rust_type(type_ref.item, False)}>"
    assert base is not None
    return f"Option<{base}>" if optional or type_ref.nullable else base



def metadata_lines() -> list[str]:
    lines = [
        "",
        "#[derive(Debug, Clone, Copy, PartialEq, Eq)]",
        "pub enum RequestBodyKind {",
        "    None,",
        "    Json,",
        "    Text,",
        "    Binary,",
        "}",
        "",
        "#[derive(Debug, Clone, Copy, PartialEq, Eq)]",
        "pub enum ResponseContentKind {",
        "    None,",
        "    Json,",
        "    Text,",
        "    Binary,",
        "    EventStream,",
        "}",
        "",
        "#[derive(Debug, Clone, Copy, PartialEq, Eq)]",
        "pub struct Response {",
        "    pub status: &'static str,",
        "    pub media_type: Option<&'static str>,",
        "    pub content_kind: ResponseContentKind,",
        "    pub type_name: Option<&'static str>,",
        "}",
        "",
        "#[derive(Debug, Clone, Copy, PartialEq, Eq)]",
        "pub struct Parameter {",
        "    pub name: &'static str,",
        "    pub location: &'static str,",
        "    pub required: bool,",
        "}",
        "",
        "#[derive(Debug, Clone, Copy, PartialEq, Eq)]",
        "pub struct OperationDescriptor {",
        "    pub id: &'static str,",
        "    pub method: &'static str,",
        "    pub path: &'static str,",
        "    pub request_body_kind: RequestBodyKind,",
        "    pub request_body_type: Option<&'static str>,",
        "    pub parameter_type: Option<&'static str>,",
        "    pub parameters: &'static [Parameter],",
        "    pub responses: &'static [Response],",
        "}",
        "",
    ]
    return lines


def enum_lines(name: str, values: tuple[str, ...]) -> list[str]:
    lines = []
    lines.append(
        "#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]"
    )
    lines.append(f"pub enum {name} {{")
    for value in values:
        variant = pascal(value)
        lines.append(f'    #[serde(rename = "{value}")]')
        lines.append(f"    {variant},")
    lines.extend(["}", ""])
    return lines


def model_lines(model: Model) -> list[str]:
    lines = []
    lines.append("#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]")
    lines.append(f"pub struct {model.name} {{")
    for item in model.fields:
        property_name = rust_name(item.wire_name)
        plain_name = property_name.removeprefix("r#")
        attrs = []
        if plain_name != item.wire_name:
            attrs.append(f'rename = "{item.wire_name}"')
        if not item.required:
            attrs.extend(["default", 'skip_serializing_if = "Option::is_none"'])
        if attrs:
            lines.append(f"    #[serde({', '.join(attrs)})]")
        lines.append(
            f"    pub {property_name}: {rust_type(item.type_ref, not item.required)},"
        )
    if model.additional_properties is not None:
        lines.append("    #[serde(flatten)]")
        lines.append(
            "    pub additional_properties: std::collections::BTreeMap<String, "
            f"{rust_type(model.additional_properties, False)}>,"
        )
    lines.append("}")
    lines.append("")
    return lines


def operation_lines(operation: Operation) -> list[str]:
    lines = []
    lines.append(
        f"pub const {screaming_snake(operation.operation_id)}_PARAMETERS: &[Parameter] = &["
    )
    for parameter in operation.parameters:
        required = "true" if parameter.required else "false"
        lines.extend(
            [
                "    Parameter {",
                f'        name: "{parameter.name}",',
                f'        location: "{parameter.location}",',
                f"        required: {required},",
                "    },",
            ]
        )
    lines.extend(["];", ""])
    lines.append(
        f"pub const {screaming_snake(operation.operation_id)}_RESPONSES: &[Response] = &["
    )
    for response in operation.responses:
        type_name = f'Some("{response.type_name}")' if response.type_name else "None"
        media_type = f'Some("{response.media_type}")' if response.media_type else "None"
        lines.extend(
            [
                "    Response {",
                f'        status: "{response.status}",',
                f"        media_type: {media_type},",
                f"        content_kind: ResponseContentKind::{response.content_kind[:1].upper() + response.content_kind[1:]},",
                f"        type_name: {type_name},",
                "    },",
            ]
        )
    lines.extend(["];", ""])
    lines.extend(
        [
            f"pub const {screaming_snake(operation.operation_id)}: OperationDescriptor = OperationDescriptor {{",
            f'    id: "{operation.operation_id}",',
            f'    method: "{operation.method}",',
            f'    path: "{operation.path}",',
            f"    request_body_kind: RequestBodyKind::{operation.request_kind.title()},",
            "    request_body_type: "
            + (f'Some("{operation.request_type}")' if operation.request_type else "None")
            + ",",
            "    parameter_type: "
            + (f'Some("{operation.parameter_type}")' if operation.parameter_type else "None")
            + ",",
            f"    parameters: {screaming_snake(operation.operation_id)}_PARAMETERS,",
            f"    responses: {screaming_snake(operation.operation_id)}_RESPONSES,",
            "};",
        ]
    )
    return lines


def referenced_names(type_ref: TypeRef) -> set[str]:
    names = {type_ref.name} if type_ref.name else set()
    return names | (referenced_names(type_ref.item) if type_ref.item else set())


def rust_file(digest: str, lines: list[str], imports: set[str] | None = None) -> str:
    header = [f"// Generated by tools/generate_openapi_clients.py; OpenAPI SHA-256: {digest}. Do not edit.", ""]
    if imports:
        header.extend(["use crate::generated::{" + ", ".join(sorted(imports)) + "};", ""])
    return "\n".join(header + lines + [""])


def render_rust_files(contract: ContractModel, digest: str) -> dict[str, str]:
    files = {"metadata.rs": rust_file(digest, metadata_lines())}
    names = []
    for name, values in contract.enums.items():
        files[f"types/{name[0].lower()}/{snake(name)}.rs"] = rust_file(digest, enum_lines(name, values))
        names.append(name)
    for name, type_ref in contract.aliases.items():
        files[f"types/{name[0].lower()}/{snake(name)}.rs"] = rust_file(
            digest, [f"pub type {name} = {rust_type(type_ref, False)};"], referenced_names(type_ref) - {name}
        )
        names.append(name)
    for model in contract.models.values():
        imports = set().union(*(referenced_names(item.type_ref) for item in model.fields))
        if model.additional_properties:
            imports |= referenced_names(model.additional_properties)
        files[f"types/{model.name[0].lower()}/{snake(model.name)}.rs"] = rust_file(
            digest, model_lines(model), imports - {model.name}
        )
        names.append(model.name)
    if len({snake(name).casefold() for name in names}) != len(names):
        raise ValueError("Generated Rust types have colliding module names")
    operation_modules = [snake(operation.operation_id) for operation in contract.operations]
    if len(set(operation_modules)) != len(operation_modules):
        raise ValueError("Generated Rust operations have colliding module names")
    letters = sorted({name[0].lower() for name in names})
    for letter in letters:
        declarations = []
        for name in sorted(name for name in names if name[0].lower() == letter):
            module = snake(name)
            declarations.extend([f"mod {module};", f"pub use {module}::{name};", ""])
        files[f"types/{letter}/mod.rs"] = rust_file(digest, declarations)
    files["types/mod.rs"] = rust_file(
        digest, [line for letter in letters for line in (f"mod {letter};", f"pub use {letter}::*;", "")]
    )
    operations = ["use super::OperationDescriptor;", ""]
    for operation in contract.operations:
        module = snake(operation.operation_id)
        imports = {"Parameter", "Response", "OperationDescriptor", "RequestBodyKind"}
        if operation.responses:
            imports.add("ResponseContentKind")
        files[f"operations/{module}.rs"] = rust_file(digest, operation_lines(operation), imports)
        operations.extend([f"mod {module};", f"pub use {module}::*;"])
    operations.extend(["", "pub const OPERATIONS: &[OperationDescriptor] = &["])
    operations.extend(f"    {screaming_snake(operation.operation_id)}," for operation in contract.operations)
    operations.append("];")
    files["operations/mod.rs"] = rust_file(digest, operations)
    files["mod.rs"] = rust_file(digest, [
        "mod metadata;", "pub use metadata::*;", "", "mod types;", "pub use types::*;", "",
        "mod operations;", "pub use operations::*;",
    ])
    return files


def render_rust(contract: ContractModel, digest: str) -> str:
    return "\n".join(render_rust_files(contract, digest).values())
