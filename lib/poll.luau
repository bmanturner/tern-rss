--!strict
-- Pane liveness for host-side loops; host half only (uses tern.pane).

local poll = {}

-- Whether pane `pane` still exists on this host (blocks have no close hook).
function poll.alive(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

return poll
