//! JSON-lines oracle consumed by scripts/test_standalone_contract.sh.
use aimonitor_core::{
    device::Location,
    plugin::{parse_manifest, SceneLayout},
    protocol::Theme,
    standalone::{export_profile, parse_profile},
};
use serde_json::{json, Value};
fn main() {
    let location = Location {
        name: "Köln".into(),
        latitude: 50.94,
        longitude: 6.96,
    };
    for kind in ["weather", "status"] {
        let (manifest, response) = if kind == "weather" {
            (
                include_bytes!("../../../../tests/fixtures/standalone-weather/plugin.json")
                    .as_slice(),
                include_bytes!("../../../../tests/fixtures/standalone-weather/response.json")
                    .as_slice(),
            )
        } else {
            (
                include_bytes!("../../../../tests/fixtures/standalone-status/plugin.json")
                    .as_slice(),
                include_bytes!("../../../../tests/fixtures/standalone-status/response.json")
                    .as_slice(),
            )
        };
        let mut manifest = parse_manifest(manifest).unwrap();
        if kind == "status" {
            // Valid desktop spellings must be canonicalized before the
            // firmware's deliberately smaller URL parser receives them.
            manifest.source.url =
                Some("HTTPS://%73tatus.example.org:443/api/v2/status.json".into());
            let b = &mut manifest.bindings[2];
            for (k, v) in [
                ("1.0", "Operational"),
                ("1e+20", "Operational"),
                ("0.00001", "Operational"),
                ("0.12345678901234568", "Operational"),
                ("-3238981266695655.5", "Operational"),
                ("4.791913706349925e+30", "Operational"),
                ("-5.060218328469913e-15", "Operational"),
                ("{\"a\":1,\"b\":2}", "Operational"),
            ] {
                b.map.insert(k.into(), v.into());
            }
        }
        if kind == "status" {
            manifest.bindings[2].map.insert(
                serde_json::to_string(&json!({"\n\t\r\u{0008}\u{000c}":1})).unwrap(),
                "Operational".into(),
            );
        }
        let data: Value = serde_json::from_slice(response).unwrap();
        for layout in [
            SceneLayout::Portrait,
            SceneLayout::Landscape,
            SceneLayout::Square,
        ] {
            for theme in [Theme::Dark, Theme::Light] {
                for locale in ["en", "de"] {
                    let exported = export_profile(
                        &manifest,
                        &manifest.default_settings(),
                        layout,
                        theme,
                        locale,
                        Some(&location),
                    )
                    .unwrap();
                    let profile = parse_profile(exported.profile.as_bytes()).unwrap();
                    for scenario in [
                        "success",
                        "missing",
                        "negative-half",
                        "positive-half",
                        "trim",
                        "visibility",
                        "unicode-boundary",
                        "null",
                        "float-map",
                        "exponent-map",
                        "small-map",
                        "precise-map",
                        "object-map",
                        "control-object-map",
                        "raw-wire-precision",
                        "raw-wire-positive",
                        "raw-wire-negative",
                    ] {
                        let mut data = data.clone();
                        match scenario {
                            "missing" => data = json!({}),
                            "float-map" if kind == "status" => {
                                data["status"]["indicator"] = json!(1.0)
                            }
                            "exponent-map" if kind == "status" => {
                                data["status"]["indicator"] = json!(1e20)
                            }
                            "small-map" if kind == "status" => {
                                data["status"]["indicator"] = json!(0.00001)
                            }
                            "precise-map" if kind == "status" => {
                                data["status"]["indicator"] = json!(0.12345678901234568)
                            }
                            "control-object-map" if kind == "status" => {
                                data["status"]["indicator"] = json!({"\n\t\r\u{0008}\u{000c}":1})
                            }
                            "object-map" if kind == "status" => {
                                data["status"]["indicator"] = json!({"b":2,"a":1})
                            }
                            "null" => {
                                data = json!({"current":{"temperature_2m":null,"weather_code":null},"page":{"name":null},"status":{"indicator":null,"description":null}})
                            }
                            "negative-half" if kind == "weather" => {
                                data["current"]["temperature_2m"] = json!(-18.25);
                                data["extra"]["feet"][0] = json!(2.5 / 0.3048);
                            }
                            "positive-half" if kind == "weather" => {
                                data["current"]["temperature_2m"] = json!(18.35);
                            }
                            "trim" if kind == "status" => {
                                data["page"]["name"] = json!("  \t  ");
                                data["status"]["indicator"] = json!(" maintenance ");
                            }
                            "visibility" if kind == "status" => {
                                data["status"]["indicator"] = json!("unknown");
                            }
                            "unicode-boundary" if kind == "status" => {
                                data["page"]["name"] = json!("ü".repeat(32));
                            }
                            _ => {}
                        }
                        // Exercise the original response bytes as received from
                        // HTTP. Serializing a pre-parsed Value would hide
                        // differences between host and firmware number parsers.
                        let response_json = match (kind, scenario) {
                            ("status", "raw-wire-precision") =>
                                r#"{"status":{"indicator":-32389812666956553e-1}}"#.into(),
                            ("status", "raw-wire-positive") =>
                                r#"{"status":{"indicator":47919137063499249e14}}"#.into(),
                            ("status", "raw-wire-negative") =>
                                r#"{"status":{"indicator":-50602183284699133e-31}}"#.into(),
                            ("weather", "raw-wire-precision") =>
                                r#"{"current":{"temperature_2m":18.35,"weather_code":0},"extra":{"feet":[8.202099737532809]}}"#.into(),
                            ("weather", "raw-wire-positive") =>
                                r#"{"current":{"temperature_2m":18.35,"weather_code":0}}"#.into(),
                            ("weather", "raw-wire-negative") =>
                                r#"{"current":{"temperature_2m":-18.25,"weather_code":0}}"#.into(),
                            _ => serde_json::to_string(&data).unwrap(),
                        };
                        let data = serde_json::from_str(&response_json).unwrap();
                        let expected = manifest
                            .scene_at(
                                layout,
                                &data,
                                &manifest.default_settings(),
                                theme,
                                locale,
                                Some(&location),
                            )
                            .unwrap();
                        assert_eq!(profile.render(response_json.as_bytes()).unwrap(), expected);
                        println!(
                            "{}",
                            json!({"name":format!("{kind}-{layout:?}-{theme:?}-{locale}-{scenario}"),"profile":profile,"profileJson":exported.profile,"response":data,"responseJson":response_json,"expected":expected})
                        );
                    }
                }
            }
        }
    }
}
