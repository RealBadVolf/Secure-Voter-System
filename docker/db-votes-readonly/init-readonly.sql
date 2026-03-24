-- Applied after schema init. Restricts sv_verify_user to SELECT-only.
-- This simulates the Zone 5 read-only replica access controls.

USE securevote_votes;
REVOKE ALL PRIVILEGES ON securevote_votes.* FROM 'sv_verify_user'@'%';
GRANT SELECT ON securevote_votes.vote_casts TO 'sv_verify_user'@'%';
GRANT SELECT ON securevote_votes.merkle_trees TO 'sv_verify_user'@'%';
GRANT SELECT ON securevote_votes.merkle_nodes TO 'sv_verify_user'@'%';
GRANT SELECT ON securevote_votes.merkle_hierarchy TO 'sv_verify_user'@'%';
GRANT SELECT, INSERT ON securevote_votes.verification_attempts TO 'sv_verify_user'@'%';
FLUSH PRIVILEGES;
