#
# Table structure for table 'blogs'
#

CREATE TABLE blogs (
  userid bigint(20) default NULL,
  blogid bigint(20) default NULL,
  defaultblog char(1) default NULL,
  blogdesc varchar(50) default NULL
);

#
# Table structure for table 'users'
#

CREATE TABLE users (
  id bigint(20) NOT NULL auto_increment,
  blogname varchar(50) default NULL,
  nick varchar(30) default NULL,
  password varchar(30) default NULL,
  PRIMARY KEY  (id)
);

