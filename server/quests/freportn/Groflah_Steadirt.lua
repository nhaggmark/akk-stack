-- items: 18818
local llm_bridge = require("llm_bridge")

local quest_hints = {
    "You are Groflah Steadirt, a weapon merchant and smith who runs Groflah's Forge in North Freeport.",
    "You sell fine blades and weapons to adventurers — quality is your pride.",
    "You are nervous about discussing Zimel's Blades — a burned-out former competitor with a mysterious past.",
    "If pressed about Ariska Zimel, you claim not to know the name and shut down the conversation immediately.",
    "A tattered flier from Zimel's Blades once came into your hands, but there's more to its history than prices.",
    "Valid keywords: [Ariska Zimel].",
}

function event_say(e)
	if(e.message:findi("hail")) then
		e.self:Say("Greetings, adventurer! Certainly a person who looks as hardened as yourself deserves a fine blade to match your prowess. Here at Groflah's Forge, we supply you with only the finest quality weapons.");
	elseif(e.message:findi("ariska zimel")) then
		e.self:Say("Zimel!! I do not know who you mean. Now go away. I am very busy. I will not talk here!!");
	else
		-- LLM fallback: player said something off-keyword
		llm_bridge.send_thinking_indicator(e)
		local context = llm_bridge.build_quest_context(e, quest_hints)
		local response = llm_bridge.generate_response(context, e.message)
		if response then e.self:Say(response) end
	end
end

function event_trade(e)
	local item_lib = require("items");

	if(item_lib.check_turn_in(e.trade, {item1 = 18818})) then
		e.self:Say("Where did you find this? This was the main price list of Zimel's Blades, but it should be all burnt up. I was at Zimel's right after the fire and I did not see it hanging where it should have been. The entire inside was gutted and . . . wait . . . the sequence of the dots!! Hmmm. I cannot talk with you here. Meet me at the Seafarer's by the docks at night. Give me the note when next we meet.");
		e.other:SummonItem(18818); -- Item: Tattered Flier
	end
	item_lib.return_items(e.self, e.other, e.trade)
end
