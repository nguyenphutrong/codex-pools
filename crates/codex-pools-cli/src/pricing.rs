use crate::analytics::TokenUsage;

#[derive(Clone, Copy)]
pub struct Price {
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
}

pub fn price_for(model_name: &str) -> Option<Price> {
    let normalized = normalize_model_name(model_name)?;
    match normalized.as_str() {
        "gpt-5" => Some(Price {
            input: 1.25,
            output: 10.00,
            cache_read: 0.125,
            cache_write: 1.25,
        }),
        "gpt-5-mini" => Some(Price {
            input: 0.25,
            output: 2.00,
            cache_read: 0.025,
            cache_write: 0.25,
        }),
        "gpt-5-nano" => Some(Price {
            input: 0.05,
            output: 0.40,
            cache_read: 0.005,
            cache_write: 0.05,
        }),
        "gpt-4.1" => Some(Price {
            input: 2.00,
            output: 8.00,
            cache_read: 0.50,
            cache_write: 2.00,
        }),
        "gpt-4.1-mini" => Some(Price {
            input: 0.40,
            output: 1.60,
            cache_read: 0.10,
            cache_write: 0.40,
        }),
        "gpt-4.1-nano" => Some(Price {
            input: 0.10,
            output: 0.40,
            cache_read: 0.025,
            cache_write: 0.10,
        }),
        "gpt-4o" => Some(Price {
            input: 2.50,
            output: 10.00,
            cache_read: 1.25,
            cache_write: 2.50,
        }),
        "gpt-4o-mini" => Some(Price {
            input: 0.15,
            output: 0.60,
            cache_read: 0.075,
            cache_write: 0.15,
        }),
        "o3" => Some(Price {
            input: 2.00,
            output: 8.00,
            cache_read: 0.50,
            cache_write: 2.00,
        }),
        "o3-mini" => Some(Price {
            input: 1.10,
            output: 4.40,
            cache_read: 0.55,
            cache_write: 1.10,
        }),
        "o4-mini" => Some(Price {
            input: 1.10,
            output: 4.40,
            cache_read: 0.275,
            cache_write: 1.10,
        }),
        "codex-mini-latest" => Some(Price {
            input: 1.50,
            output: 6.00,
            cache_read: 0.375,
            cache_write: 1.50,
        }),
        _ => None,
    }
}

pub fn estimated_cost(model_name: &str, usage: &TokenUsage) -> Option<f64> {
    let price = price_for(model_name)?;
    Some(
        (usage.input_tokens as f64 / 1_000_000.0 * price.input)
            + (usage.output_tokens as f64 / 1_000_000.0 * price.output)
            + (usage.cache_read_tokens as f64 / 1_000_000.0 * price.cache_read)
            + (usage.cache_write_tokens as f64 / 1_000_000.0 * price.cache_write),
    )
}

pub fn normalize_model_name(model_name: &str) -> Option<String> {
    let mut value = model_name.trim().to_lowercase();
    if value.is_empty() {
        return None;
    }
    for prefix in ["openai/", "openai:", "azure/", "azure:", "models/"] {
        if let Some(stripped) = value.strip_prefix(prefix) {
            value = stripped.to_string();
        }
    }
    for suffix in ["-latest", "-preview"] {
        if value.ends_with(suffix) && value != "codex-mini-latest" {
            value.truncate(value.len() - suffix.len());
        }
    }
    Some(value)
}
