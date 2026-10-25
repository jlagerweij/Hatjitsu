module.exports = {
  // configuration here without worrying about the quotes
  development: {
    hostname: "localhost",
    port: 5000,
    packAssets: false
  },
  test: {
    hostname: "localhost",
    port: 0,
    packAssets: false
  },
  production: {
    hostname: "hatjitsu.herokuapp.com",
    port: 80,
    packAssets: false
  }
};
