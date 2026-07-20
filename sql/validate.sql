SELECT * FROM audit.network_summary;
SELECT
  COUNT(*) FILTER (WHERE source IS NULL OR target IS NULL) AS null_node_count,
  COUNT(*) FILTER (WHERE source = target) AS self_loop_count,
  COUNT(*) FILTER (WHERE length_m <= 0) AS non_positive_length_count,
  COUNT(*) FILTER (WHERE cost < 0 OR reverse_cost < 0) AS negative_cost_count
FROM routing.road_edges;
