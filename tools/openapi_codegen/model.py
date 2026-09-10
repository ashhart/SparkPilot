"""Schema normalization, model registration and operation coverage."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Any

from .naming import lower_camel, pascal
from .normalization import canonical_json

HTTP_METHODS = ("get", "put", "post", "delete", "patch")
SUPPORTED_SCHEMA_KEYWORDS = {
    "$ref",
    "additionalProperties",
    "const",
    "contentEncoding",
    "default",
    "deprecated",
    "description",
    "enum",
    "example",
    "examples",
    "exclusiveMaximum",
    "exclusiveMinimum",
    "format",
    "items",
    "maxItems",
    "maxLength",
    "maxProperties",
    "maximum",
    "minItems",
    "minLength",
    "minProperties",
    "minimum",
    "multipleOf",
    "oneOf",
    "pattern",
    "properties",
    "readOnly",
    "required",
    "title",
    "type",
    "uniqueItems",
    "writeOnly",
}
ANNOTATION_SCHEMA_KEYWORDS = {
    "default",
    "deprecated",
    "description",
    "example",
    "examples",
    "readOnly",
    "title",
    "writeOnly",
}



@dataclass(frozen=True)
class TypeRef:
    kind: str
    name: str | None = None
    item: "TypeRef | None" = None
    nullable: bool = False


@dataclass(frozen=True)
class Field:
    wire_name: str
    required: bool
    type_ref: TypeRef


@dataclass
class Model:
    name: str
    fields: list[Field] = field(default_factory=list)
    additional_properties: TypeRef | None = None


@dataclass(frozen=True)
class Operation:
    operation_id: str
    method: str
    path: str
    request_kind: str
    request_type: str | None
    parameter_type: str | None
    parameters: tuple["Parameter", ...]
    responses: tuple["Response", ...]


@dataclass(frozen=True)
class Response:
    status: str
    media_type: str | None
    content_kind: str
    type_name: str | None


@dataclass(frozen=True)
class Parameter:
    name: str
    location: str
    required: bool


class ContractModel:
    def __init__(self, document: dict[str, Any]) -> None:
        self.document = document
        self.models: dict[str, Model] = {}
        self.model_schema_identities: dict[str, str] = {}
        self.aliases: dict[str, TypeRef] = {}
        self.enums: dict[str, tuple[str, ...]] = {}
        self.operations: list[Operation] = []

    def resolve(self, schema: dict[str, Any]) -> dict[str, Any]:
        ref = schema.get("$ref")
        if not ref:
            return schema
        prefix = "#/components/schemas/"
        if not ref.startswith(prefix):
            raise ValueError(f"unsupported non-local schema reference: {ref}")
        return self.document["components"]["schemas"][ref.removeprefix(prefix)]

    def validate_schema_support(self, schema: dict[str, Any], name: str) -> None:
        unsupported = sorted(set(schema) - SUPPORTED_SCHEMA_KEYWORDS)
        if unsupported:
            rendered = ", ".join(unsupported)
            raise ValueError(f"{name} uses unsupported JSON Schema keyword(s): {rendered}")
        if "$ref" in schema:
            structural_siblings = set(schema) - ANNOTATION_SCHEMA_KEYWORDS - {"$ref"}
            if structural_siblings:
                raise ValueError(
                    f"{name} combines $ref with unsupported structural sibling(s): "
                    + ", ".join(sorted(structural_siblings))
                )
        raw_type = schema.get("type")
        supported_types = {"array", "boolean", "integer", "number", "object", "string"}
        if isinstance(raw_type, list):
            if len(raw_type) != len(set(raw_type)):
                raise ValueError(f"{name} uses a type array with duplicate entries")
            non_null = [item for item in raw_type if item != "null"]
            if len(non_null) != 1:
                raise ValueError(
                    f"{name} uses unsupported type array; exactly one non-null type "
                    "plus optional null is supported"
                )
            raw_members = set(raw_type) - {"null"}
            if not raw_members.issubset(supported_types):
                raise ValueError(f"{name} uses an unsupported JSON Schema type")
        elif raw_type is not None and raw_type not in supported_types:
            raise ValueError(f"{name} uses an unsupported JSON Schema type")
        elif raw_type is None and "$ref" not in schema and "oneOf" not in schema:
            structural = set(schema) - ANNOTATION_SCHEMA_KEYWORDS
            if structural:
                raise ValueError(f"{name} uses an unsupported untyped constrained schema")
        if "oneOf" not in schema:
            return
        structural_siblings = set(schema) - ANNOTATION_SCHEMA_KEYWORDS - {"oneOf"}
        if structural_siblings:
            raise ValueError(
                f"{name} combines oneOf with unsupported structural sibling(s): "
                + ", ".join(sorted(structural_siblings))
            )
        choices = schema["oneOf"]
        null_choices = [choice for choice in choices if choice == {"type": "null"}]
        if len(choices) != 2 or len(null_choices) != 1:
            raise ValueError(
                f"{name} uses unsupported oneOf; only exactly one schema plus "
                "{type: null} is supported"
            )

    def type_ref(self, schema: dict[str, Any] | None, suggested_name: str) -> TypeRef:
        if not schema:
            return TypeRef("json")
        self.validate_schema_support(schema, suggested_name)
        if "$ref" in schema:
            ref = schema["$ref"]
            prefix = "#/components/schemas/"
            if not ref.startswith(prefix):
                raise ValueError(f"unsupported non-local schema reference: {ref}")
            component_name = ref.removeprefix(prefix)
            component = self.document["components"]["schemas"][component_name]
            component_type = component.get("type")
            if component_type == "object" and component.get("properties"):
                self.register_model(component_name, component)
                return TypeRef("model", name=component_name)
            if component_type == "string" and (
                "enum" in component or "const" in component
            ):
                self.register_enum(component_name, component)
                return TypeRef("enum", name=component_name)
            alias = self.type_ref(component, component_name)
            self.aliases.setdefault(component_name, alias)
            return TypeRef("alias", name=component_name)
        if "oneOf" in schema:
            choices = schema["oneOf"]
            non_null = [choice for choice in choices if choice.get("type") != "null"]
            resolved = self.type_ref(non_null[0], suggested_name)
            return TypeRef(resolved.kind, resolved.name, resolved.item, True)
        raw_type = schema.get("type")
        nullable = isinstance(raw_type, list) and "null" in raw_type
        if isinstance(raw_type, list):
            non_null = [item for item in raw_type if item != "null"]
            raw_type = non_null[0] if len(non_null) == 1 else None
        if "$ref" in schema:
            raise AssertionError("references must be resolved")
        if raw_type == "string" and ("enum" in schema or "const" in schema):
            self.register_enum(suggested_name, schema)
            return TypeRef("enum", name=suggested_name, nullable=nullable)
        if raw_type == "string":
            return TypeRef("string", nullable=nullable)
        if raw_type == "integer":
            return TypeRef("integer", nullable=nullable)
        if raw_type == "number":
            return TypeRef("number", nullable=nullable)
        if raw_type == "boolean":
            return TypeRef("boolean", nullable=nullable)
        if raw_type == "array":
            return TypeRef(
                "array",
                item=self.type_ref(schema.get("items"), suggested_name + "Item"),
                nullable=nullable,
            )
        if (
            raw_type == "object"
            and not schema.get("properties")
            and schema.get("additionalProperties") is not False
        ):
            additional = schema.get("additionalProperties", True)
            item = (
                TypeRef("json")
                if additional is True
                else self.type_ref(additional, suggested_name + "Value")
            )
            return TypeRef("map", item=item, nullable=nullable)
        if raw_type == "object" and schema.get("properties"):
            self.register_model(suggested_name, schema)
            return TypeRef("model", name=suggested_name, nullable=nullable)
        if raw_type == "object" and schema.get("additionalProperties") is False:
            self.register_model(suggested_name, schema)
            return TypeRef("model", name=suggested_name, nullable=nullable)
        return TypeRef("json", nullable=nullable)

    def register_model(self, name: str, schema: dict[str, Any]) -> None:
        self.validate_schema_support(schema, name)
        resolved_schema = self.resolve(schema)
        self.validate_schema_support(resolved_schema, name)
        schema_identity = hashlib.sha256(canonical_json(resolved_schema)).hexdigest()
        if name in self.models:
            if self.model_schema_identities[name] != schema_identity:
                raise ValueError(f"conflicting generated model name: {name}")
            return
        model = Model(name)
        self.model_schema_identities[name] = schema_identity
        self.models[name] = model
        try:
            required = set(resolved_schema.get("required", []))
            for wire_name, property_schema in resolved_schema.get("properties", {}).items():
                model.fields.append(
                    Field(
                        wire_name=wire_name,
                        required=wire_name in required,
                        type_ref=self.type_ref(property_schema, name + pascal(wire_name)),
                    )
                )
            additional = resolved_schema.get("additionalProperties", True)
            if additional is not False:
                if any(
                    lower_camel(item.wire_name) == "additionalProperties"
                    for item in model.fields
                ):
                    raise ValueError(
                        f"{name} cannot model unknown fields because a declared property "
                        "maps to additionalProperties"
                    )
                model.additional_properties = (
                    TypeRef("json")
                    if additional is True
                    else self.type_ref(additional, name + "AdditionalProperty")
                )
        except Exception:
            self.models.pop(name, None)
            self.model_schema_identities.pop(name, None)
            raise

    def register_enum(self, name: str, schema: dict[str, Any]) -> None:
        values = schema.get("enum", [schema.get("const")])
        if not values or any(not isinstance(value, str) for value in values):
            raise ValueError(f"{name} has a non-string or empty enum")
        normalized = tuple(values)
        previous = self.enums.setdefault(name, normalized)
        if previous != normalized:
            raise ValueError(f"conflicting generated enum name: {name}")

    def resolve_parameter(self, parameter: dict[str, Any]) -> dict[str, Any]:
        ref = parameter.get("$ref")
        if not ref:
            return parameter
        prefix = "#/components/parameters/"
        if not ref.startswith(prefix):
            raise ValueError(f"unsupported parameter reference: {ref}")
        return self.document["components"]["parameters"][ref.removeprefix(prefix)]

    def resolve_response(self, response: dict[str, Any]) -> dict[str, Any]:
        ref = response.get("$ref")
        if not ref:
            return response
        prefix = "#/components/responses/"
        if not ref.startswith(prefix):
            raise ValueError(f"unsupported response reference: {ref}")
        return self.document["components"]["responses"][ref.removeprefix(prefix)]

    def content_shape(
        self, content: dict[str, Any], suggested_name: str
    ) -> tuple[str, str | None]:
        shapes = self.content_shapes(content, suggested_name)
        if len(shapes) != 1:
            raise ValueError(
                f"{suggested_name} declares {len(content)} media types; generator requires one"
            )
        _, content_kind, type_name = shapes[0]
        return content_kind, type_name

    def content_shapes(
        self, content: dict[str, Any], suggested_name: str
    ) -> list[tuple[str | None, str, str | None]]:
        if not content:
            return [(None, "none", None)]
        shapes = []
        for content_type, media in content.items():
            schema = media.get("schema")
            media_name = suggested_name
            if len(content) > 1:
                media_name += pascal(content_type)
            if content_type == "application/json" or content_type.endswith("+json"):
                if not schema:
                    shapes.append((content_type, "json", None))
                    continue
                type_ref = self.type_ref(schema, media_name)
                if type_ref.kind in {"model", "alias"}:
                    shapes.append((content_type, "json", type_ref.name))
                    continue
                alias_name = media_name
                self.aliases.setdefault(alias_name, type_ref)
                shapes.append((content_type, "json", alias_name))
                continue
            if content_type == "text/event-stream":
                shapes.append((content_type, "eventStream", None))
                continue
            if content_type in {"application/octet-stream", "audio/wav"}:
                shapes.append((content_type, "binary", None))
                continue
            if content_type.startswith("text/"):
                shapes.append((content_type, "text", None))
                continue
            raise ValueError(f"unsupported media type {content_type} in {suggested_name}")
        return shapes

    def build(self) -> None:
        for name, schema in sorted(self.document["components"]["schemas"].items()):
            if schema.get("type") == "object" and schema.get("properties"):
                self.register_model(name, schema)
            else:
                type_ref = self.type_ref(schema, name)
                if type_ref.kind != "enum":
                    self.aliases[name] = type_ref

        seen_ids: set[str] = set()
        for path in sorted(self.document["paths"]):
            path_item = self.document["paths"][path]
            for method in HTTP_METHODS:
                operation = path_item.get(method)
                if not operation:
                    continue
                operation_id = operation["operationId"]
                if operation_id in seen_ids:
                    raise ValueError(f"duplicate operationId: {operation_id}")
                seen_ids.add(operation_id)
                request_kind = "none"
                request_type = None
                content = operation.get("requestBody", {}).get("content", {})
                if content:
                    request_kind, request_type = self.content_shape(
                        content, pascal(operation_id) + "Request"
                    )

                parameters = [
                    self.resolve_parameter(parameter)
                    for parameter in [
                        *path_item.get("parameters", []),
                        *operation.get("parameters", []),
                    ]
                ]
                parameter_type = None
                if parameters:
                    parameter_type = pascal(operation_id) + "Parameters"
                    parameter_schema = {
                        "type": "object",
                        "required": [
                            parameter["name"]
                            for parameter in parameters
                            if parameter.get("required", False)
                        ],
                        "properties": {
                            parameter["name"]: parameter.get("schema", {})
                            for parameter in parameters
                        },
                    }
                    self.register_model(parameter_type, parameter_schema)
                parameter_metadata = tuple(
                    Parameter(
                        parameter["name"],
                        parameter["in"],
                        parameter.get("required", False),
                    )
                    for parameter in parameters
                )

                responses = []
                for status, response in operation["responses"].items():
                    resolved_response = self.resolve_response(response)
                    shapes = self.content_shapes(
                        resolved_response.get("content", {}),
                        pascal(operation_id) + "Response" + pascal(str(status)),
                    )
                    responses.extend(
                        Response(str(status), media_type, content_kind, type_name)
                        for media_type, content_kind, type_name in shapes
                    )
                self.operations.append(
                    Operation(
                        operation_id,
                        method.upper(),
                        path,
                        request_kind,
                        request_type,
                        parameter_type,
                        parameter_metadata,
                        tuple(responses),
                    )
                )

