-- Runs draw_pipeline_tb with the blue triangle sent first (green must overwrite
-- blue in the overlap). Wrapper entity because generics are not passed on the
-- command line (Windows .bat argument splitting, see scripts/sim.tcl).
entity draw_pipeline_blue_first_tb is
end entity;

architecture sim of draw_pipeline_blue_first_tb is
begin
  inner : entity work.draw_pipeline_tb
    generic map (BLUE_FIRST => true,
                 DUMP_FILE  => "draw_pipeline_blue_first.hex",
                 TB_NAME    => "draw_pipeline_blue_first_tb");
end architecture;
