local llm_bridge = require("llm_bridge")

local quest_hints = {
    "You are Basher Avisk, a troll guard — a Basher — keeping order in Grobb.",
    "Ranjor has ordered the Shaddernites to get rid of the spore guardian nearby.",
    "You know where a minstrel skeleton has been seen — by Basher Ganbaku's high post.",
    "Grobb is the home of the Trolls, followers of Cazic-Thule. Frogloks from Guk are the enemies.",
    "Valid keywords: [where the minstrel], [Ranjor], [shaddernites], [spore guardian].",
}

function event_say(e)
	if(e.message:findi("hail")) then
		e.self:Say("Ranjor tell shaddernites to gets rids of spore guardian. Ha! Gud.");
	elseif(e.message:findi("where the minstrel")) then
		e.self:Say("Dere stewpid skeleton singing by Basher Ganbaku. His post be up high.");
		eq.unique_spawn(52119,0,0,-182,313,26.7,459); -- NPC: a_skeleton
	else
		-- LLM fallback: player said something off-keyword
		llm_bridge.send_thinking_indicator(e)
		local context = llm_bridge.build_quest_context(e, quest_hints)
		local response = llm_bridge.generate_response(context, e.message)
		if response then e.self:Say(response) end
	end
end
