alias Omni.{Context, Schema}

Omni.Provider.load(openrouter: Omni.Providers.OpenRouter)

context = Context.new("Create a person")

schema = Schema.object(%{
  name: Schema.string(description: "Full name"),
  star_sign: Schema.string(description: "Zodiac star sign"),
  occupation: Schema.string(description: "Role or occupation"),
  skill: Schema.string(description: "Secret skill")
}, required: [:name, :star_sign, :occupation, :skill])

# Omni.generate_text({:anthropic, "claude-haiku-4-5"}, context, output: schema)
# Omni.generate_text({:google, "gemini-3-flash-preview"}, context, output: schema)
# Omni.generate_text({:openai, "gpt-5-mini"}, context, output: schema)
# Omni.generate_text({:openrouter, "openai/gpt-5-mini"}, context, output: schema)

{:ok, resp} = Omni.generate_text({:google, "gemini-3-flash-preview"}, context, output: schema)

dbg(resp.stop_reason, label: "stop_reason")
dbg(resp.usage, label: "usage")
dbg(resp.output, label: "output")
