local llm_bridge = require("llm_bridge")

local quest_hints = {
    "You are Alec McMarrin, a Wolf of the North guard patrolling the streets of Halas.",
    "You patrol to ensure the safety of travelers and resident clans in the city.",
    "You can escort visitors to key locations in Halas: the bank, shaman guild, warrior guild, rogue guild, and the docks.",
    "Halas is the home of the Barbarians — a proud people who worship the Tribunal and value honor and strength above all.",
    "Valid keywords the player can ask about: [bank], [shaman guild], [warrior guild], [rogue guild], [dock].",
}

function event_say(e)
	if(e.message:findi("hail")) then
		e.self:Say("Hail. " .. e.other:GetCleanName() .. "! I patrol Halas to insure the safety of the travelers and the resident clans. Just ask if you need help in finding your destination.");
	elseif(e.message:findi("bank")) then
		e.self:Say("Follow me! I will lead you there.");
		eq.move_to(122, 193, 6, 213,false);
	elseif(e.message:findi("shaman guild")) then
		e.self:Say("Follow me! I will lead you there.");
		eq.move_to(332, 330, 4, 59,false);
	elseif(e.message:findi("warrior guild")) then
		e.self:Say("Follow me! I will lead you there.");
		eq.move_to(-422, 483, 4, 0,false);
	elseif(e.message:findi("rogue guild")) then
		e.self:Say("Follow me! I will lead you there.");
		eq.move_to(153, 273, 9, 64,false);
	elseif(e.message:findi("dock")) then
		e.self:Say("Follow me! I will lead you there.");
		eq.move_to(8, -17, 4, 128,false);
	else
		-- LLM fallback: player said something off-keyword
		llm_bridge.send_thinking_indicator(e)
		local context = llm_bridge.build_quest_context(e, quest_hints)
		local response = llm_bridge.generate_response(context, e.message)
		if response then e.self:Say(response) end
	end
end
