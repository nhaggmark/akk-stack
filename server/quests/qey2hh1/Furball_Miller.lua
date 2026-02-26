local llm_bridge = require("llm_bridge")

local quest_hints = {
    "You are Furball Miller, a young gnoll raised by a human farmer named Pa Miller in the Qeynos Hills.",
    "You were rescued as a pup from Blackburrow — home of the Sabertooth gnoll clan — and raised by humans.",
    "You dream of returning to Blackburrow one day to convince gnolls and humans to stop fighting.",
    "You speak with occasional bark sounds and see both gnolls and humans as kin.",
    "Valid keywords the player can ask about: [father], [Blackburrow], [gnolls].",
}

function event_say(e)
	if(e.message:findi("hail")) then
		e.self:Say("<BARK!>  Hiya!  <Bark!>  <Bark!>  My name is Furball Miller.  I work here on my father's farm.  Of course. he is not my real [father] but he is the one who raisd me from a pup.  I hope to go back to [Blackburrow] some day and try to get them to stop all the senseless fighting with the humans of Qeynos.");
	elseif(e.message:findi("blackburrow")) then
		e.self:Say("Blackburrow is home to a clan of gnolls called the Sabertooths.  It is where I am from but I really don't ever remember being there.  Pa tells me the gnolls there are always fighting with the <BARK!>  humans of Qeynos.  I wish they would stop and realize that humans and gnolls are not as different as they like to think.  <BARK!>");
	else
		-- LLM fallback: player said something off-keyword
		llm_bridge.send_thinking_indicator(e)
		local context = llm_bridge.build_quest_context(e, quest_hints)
		local response = llm_bridge.generate_response(context, e.message)
		if response then e.self:Say(response) end
	end
end

-- END of FILE Zone:qey2hh1  ID:1610 -- Furball_Miller 
