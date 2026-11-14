-- mem_mux.vhd : fixed-priority mux for the depth-buffer memory controller
-- Moved out of gpu_top unchanged (Integration 1 logic), so gpu_top and
-- draw_pipeline_tb share it and RQ-109's arbiter replaces one file.
--
-- Priority: index 0 (MEM_CLIENT_CLEAR) > 1 (MEM_CLIENT_E6) > 2 (MEM_CLIENT_E4).
-- A client's ready may depend on the other clients' valid, never on its own.
-- Responses are not routed: only E4 reads, so rsp goes straight to it.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mem_if_pkg.all;

entity mem_mux is
  port (
    reqs_i      : in  mem_req_array_t(0 to MEM_CLIENTS - 1);
    readys_o    : out std_logic_vector(0 to MEM_CLIENTS - 1);
    -- to the controller
    req_o       : out mem_req_t;
    req_ready_i : in  std_logic
  );
end entity;

architecture rtl of mem_mux is
  signal grant : natural range 0 to MEM_CLIENTS - 1;
begin
  pick : process (all)
  begin
    grant <= MEM_CLIENT_CLEAR;
    for i in MEM_CLIENTS - 1 downto 0 loop   -- lowest index assigned last, so it wins
      if reqs_i(i).valid = '1' then
        grant <= i;
      end if;
    end loop;
  end process;

  req_o <= reqs_i(grant);

  gen_ready : for i in 0 to MEM_CLIENTS - 1 generate
    readys_o(i) <= req_ready_i when grant = i else '0';
  end generate;
end architecture;
