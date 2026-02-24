alias Omni.Context

Omni.Provider.load(openrouter: Omni.Providers.OpenRouter)

context = Context.new("Create a person")

schema = Omni.Schema.object(%{
  name: Omni.Schema.string(description: "Full name"),
  star_sign: Omni.Schema.string(description: "Zodiac star sign"),
  occupation: Omni.Schema.string(description: "Role or occupation"),
  skill: Omni.Schema.string(description: "Secret skill")
}, required: [:name, :star_sign, :occupation, :skill])

# Omni.generate_text({:anthropic, "claude-haiku-4-5"}, context, output: schema)
# Omni.generate_text({:google, "gemini-3-flash-preview"}, context, output: schema)
# Omni.generate_text({:openai, "gpt-5-mini"}, context, output: schema)
# Omni.generate_text({:openrouter, "openai/gpt-5-mini"}, context, output: schema)

{:ok, resp} = Omni.generate_text({:google, "gemini-3-flash-preview"}, context, output: schema)

dbg(resp.stop_reason, label: "stop_reason")
dbg(resp.usage, label: "usage")
dbg(resp.output, label: "output")
