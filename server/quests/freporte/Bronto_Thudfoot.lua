local llm_bridge = require("llm_bridge")

local quest_hints = {
    "You are Bronto Thudfoot, a dock worker and regular at the Freeport East waterfront taverns.",
    "You witnessed a rogue fleeing the docks late one night — a tall, brawny woman who smelled of fish.",
    "You were drinking heavily that night and your memory is hazy, but you remember her silhouette.",
    "You operate in Freeport East — a rough district under the Freeport Militia's watch.",
    "Valid keywords the player can ask about: [see the rogue], [silhouette], [docks], [woman].",
}

function event_say(e)
	if(e.message:findi("hail")) then
		e.self:Say("How ya doin' bub. Seeing as you just joined the conversation, I think you need to buy us a round.");
	elseif(e.message:findi("see the rogue")) then
		e.self:Say("I had quite a bit of grog that night and it was very dark. What I do remember was seeing a tall woman in a dress run from the docks. She sort of smelled, too. Like fish. I know it was the docks, but this woman had a real stench to her. Like dried fish baking in the sun. That is all I remember. It was too dark to see anything but her [silhouette].");
	elseif(e.message:findi("silhouette")) then
		e.self:Say("Yeah!! The silhouette looked like a very brawny woman. It had to be a woman. The silhouette was surely that of one with a short skirt and long hair.");
	else
		-- LLM fallback: player said something off-keyword
		llm_bridge.send_thinking_indicator(e)
		local context = llm_bridge.build_quest_context(e, quest_hints)
		local response = llm_bridge.generate_response(context, e.message)
		if response then e.self:Say(response) end
	end
end

function event_signal(e)
	e.self:Say("You said it, boss!  Stay clear of taking sides and you should be just fine, young one.");
end
